defmodule CommsCore.PasswordRecovery do
  import Ecto.Query

  require Logger

  alias CommsCore.Accounts.{
    Device,
    NotificationCommand,
    NotificationPort,
    NotificationReceipt,
    PasswordRecoveryRequest,
    Session,
    Tenant,
    User
  }

  alias CommsCore.AudioCalls
  alias CommsCore.Audit
  alias CommsCore.Repo
  alias CommsCore.Security.Password

  @event_type "account.password_recovery.requested.v1"
  @default_ttl_seconds 1_800
  @minimum_key_bytes 32

  def event_type, do: @event_type

  def reset_command(attrs) do
    with {:ok, result} <- reset(attrs) do
      {:ok, Map.take(result, [:revoked_session_ids])}
    end
  end

  @doc """
  Accepts a recovery request without revealing whether the identity exists.

  Every path performs the same password-derivation and HMAC baseline work. For
  active identities, the durable request, redacted notification intent, and
  audit event are committed together. Operational failures are logged without
  tenant, email, token, or request material and still return `:ok` to callers.
  """
  def request(attrs) do
    started_at = System.monotonic_time(:millisecond)

    try do
      request_with_equalized_work(attrs)
    rescue
      _error ->
        Logger.error("password recovery request could not be queued")
        :ok
    after
      pad_public_response(started_at)
    end
  end

  defp request_with_equalized_work(attrs) when is_map(attrs) do
    tenant_slug = normalized_text(value(attrs, :tenant_slug))
    email = normalized_email(value(attrs, :email))
    key_result = signing_key()

    dummy_work(key_result, tenant_slug, email)
    prune_stale_requests()

    user =
      Repo.one(
        from(user in User,
          join: tenant in Tenant,
          on: tenant.id == user.tenant_id,
          where:
            tenant.slug == ^tenant_slug and tenant.status == :active and user.status == :active and
              user.account_type == :human and
              fragment("lower(?)", user.email) == ^email,
          limit: 1
        )
      )

    case {user, key_result} do
      {%User{} = user, {:ok, key}} -> create_request(user, key)
      _ -> dummy_database_work()
    end

    :ok
  end

  defp request_with_equalized_work(_attrs) do
    dummy_work(signing_key(), "", "")
    dummy_database_work()
    :ok
  end

  def reset(attrs) when is_map(attrs) do
    token = value(attrs, :token)
    new_password = value(attrs, :new_password)

    with :ok <- validate_password(new_password),
         {:ok, key} <- signing_key(),
         {:ok, request_id} <- token_request_id(token),
         %PasswordRecoveryRequest{} = preview <- Repo.get(PasswordRecoveryRequest, request_id) do
      password_hash = Password.hash(new_password)

      Repo.transaction(fn ->
        user =
          Repo.one(
            from(user in User,
              where:
                user.id == ^preview.user_id and user.tenant_id == ^preview.tenant_id and
                  user.status == :active and user.account_type == :human,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:invalid_password_recovery_token)

        recovery =
          Repo.one(
            from(request in PasswordRecoveryRequest,
              where: request.id == ^request_id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:invalid_password_recovery_token)

        unless recovery.user_id == user.id and recovery.tenant_id == user.tenant_id and
                 valid_recovery_token?(recovery, token, key) do
          Repo.rollback(:invalid_password_recovery_token)
        end

        timestamp = now()

        recovery
        |> PasswordRecoveryRequest.changeset(%{consumed_at: timestamp})
        |> update_or_rollback()

        from(request in PasswordRecoveryRequest,
          where:
            request.user_id == ^user.id and request.id != ^recovery.id and
              is_nil(request.consumed_at) and is_nil(request.invalidated_at)
        )
        |> Repo.update_all(set: [invalidated_at: timestamp, updated_at: timestamp])

        updated_user =
          user
          |> User.changeset(%{password_hash: password_hash})
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        revoked_session_ids = revoke_access!(updated_user, timestamp)

        Audit.record(%{
          tenant_id: user.tenant_id,
          actor_user_id: nil,
          action: "password_recovery.consume",
          resource_type: "password_recovery_request",
          resource_id: recovery.id,
          metadata: %{
            source: "public_recovery",
            revoked_session_count: length(revoked_session_ids)
          }
        })
        |> audit_or_rollback()

        %{user: updated_user, revoked_session_ids: revoked_session_ids}
      end)
      |> transaction_result()
    else
      {:error, :password_recovery_unavailable} = error -> error
      {:error, :weak_password} = error -> error
      _ -> {:error, :invalid_password_recovery_token}
    end
  end

  def reset(_attrs), do: {:error, :invalid_password_recovery_token}

  @doc """
  Materializes the recovery destination and action URL immediately before
  provider dispatch. The raw token and URL are never persisted or returned by
  ordinary notification APIs.
  """
  def materialize_notification(%{
        tenant_id: tenant_id,
        user_id: user_id,
        recovery_request_id: request_id
      }) do
    with {:ok, key} <- signing_key(),
         true <- is_binary(request_id),
         %PasswordRecoveryRequest{} = recovery <-
           Repo.get_by(PasswordRecoveryRequest,
             id: request_id,
             tenant_id: tenant_id,
             user_id: user_id
           ),
         true <- deliverable?(recovery),
         %User{status: :active} = user <-
           Repo.get_by(User,
             id: user_id,
             tenant_id: tenant_id,
             account_type: :human
           ),
         token <- materialize_token(recovery.id, key),
         true <- secure_digest_equals(recovery.token_hash, token),
         {:ok, app_url} <- public_app_url() do
      {:ok,
       %{
         destination: user.email,
         payload: %{
           "title" => "Reset your K-Comms password",
           "body" => "Use the secure recovery link to choose a new password.",
           "action_url" =>
             String.trim_trailing(app_url, "/") <>
               "/reset-password#token=" <> URI.encode_www_form(token)
         }
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :password_recovery_not_deliverable}
    end
  end

  def materialize_notification(_intent), do: {:error, :password_recovery_not_deliverable}

  defp create_request(user, key) do
    case Repo.transaction(fn ->
           timestamp = now()

           locked_user =
             Repo.one(
               from(candidate in User,
                 where:
                   candidate.id == ^user.id and candidate.tenant_id == ^user.tenant_id and
                     candidate.status == :active,
                 lock: "FOR UPDATE"
               )
             ) || Repo.rollback(:not_found)

           from(request in PasswordRecoveryRequest,
             where:
               request.user_id == ^locked_user.id and is_nil(request.consumed_at) and
                 is_nil(request.invalidated_at)
           )
           |> Repo.update_all(set: [invalidated_at: timestamp, updated_at: timestamp])

           request_id = Ecto.UUID.generate()
           token = materialize_token(request_id, key)

           recovery =
             %PasswordRecoveryRequest{id: request_id}
             |> PasswordRecoveryRequest.changeset(%{
               tenant_id: user.tenant_id,
               user_id: locked_user.id,
               token_hash: :crypto.hash(:sha256, token),
               expires_at: DateTime.add(timestamp, recovery_ttl_seconds(), :second)
             })
             |> insert_or_rollback()

           receipt =
             NotificationCommand.password_recovery(
               locked_user.tenant_id,
               locked_user.id,
               locked_user.email,
               recovery.id
             )
             |> NotificationPort.execute()
             |> notification_receipt_or_rollback()

           Audit.record(%{
             tenant_id: locked_user.tenant_id,
             actor_user_id: nil,
             action: "password_recovery.request",
             resource_type: "password_recovery_request",
             resource_id: recovery.id,
             metadata: %{source: "public_recovery", notification_intent_id: receipt.id}
           })
           |> audit_or_rollback()

           recovery
         end) do
      {:ok, _recovery} -> :ok
      {:error, _reason} -> Logger.error("password recovery request could not be queued")
    end
  end

  defp valid_recovery_token?(recovery, token, key) do
    deliverable?(recovery) and is_binary(token) and
      secure_text_equals(materialize_token(recovery.id, key), token) and
      secure_digest_equals(recovery.token_hash, token)
  end

  defp deliverable?(recovery) do
    is_nil(recovery.consumed_at) and is_nil(recovery.invalidated_at) and
      DateTime.compare(recovery.expires_at, now()) == :gt
  end

  defp materialize_token(request_id, key) do
    nonce = :crypto.mac(:hmac, :sha256, key, "password-recovery:nonce:v1:#{request_id}")
    encoded_nonce = Base.url_encode64(nonce, padding: false)
    unsigned = "#{request_id}.#{encoded_nonce}"
    signature = :crypto.mac(:hmac, :sha256, key, "password-recovery:token:v1:#{unsigned}")
    "#{unsigned}.#{Base.url_encode64(signature, padding: false)}"
  end

  defp token_request_id(token) when is_binary(token) do
    case String.split(token, ".", parts: 3) do
      [request_id, nonce, signature] when nonce != "" and signature != "" ->
        case Ecto.UUID.cast(request_id) do
          {:ok, _uuid} -> {:ok, request_id}
          :error -> {:error, :invalid_password_recovery_token}
        end

      _ ->
        {:error, :invalid_password_recovery_token}
    end
  end

  defp token_request_id(_token), do: {:error, :invalid_password_recovery_token}

  defp signing_key do
    case Application.get_env(:comms_core, :password_recovery_signing_key) do
      key when is_binary(key) and byte_size(key) >= @minimum_key_bytes -> {:ok, key}
      _ -> {:error, :password_recovery_unavailable}
    end
  end

  defp public_app_url do
    case Application.get_env(:comms_core, :public_app_url) do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ -> {:error, :password_recovery_unavailable}
    end
  end

  defp recovery_ttl_seconds do
    Application.get_env(:comms_core, :password_recovery_ttl_seconds, @default_ttl_seconds)
    |> min(1_800)
    |> max(900)
  end

  defp prune_stale_requests do
    retention_seconds =
      Application.get_env(:comms_core, :password_recovery_retention_seconds, 2_592_000)
      |> min(7_776_000)
      |> max(604_800)

    cutoff = DateTime.add(now(), -retention_seconds, :second)

    stale_ids =
      from(request in PasswordRecoveryRequest,
        where:
          request.expires_at < ^cutoff or request.consumed_at < ^cutoff or
            request.invalidated_at < ^cutoff,
        order_by: [asc: request.expires_at],
        limit: 500,
        select: request.id
      )

    Repo.delete_all(
      from(request in PasswordRecoveryRequest, where: request.id in subquery(stale_ids))
    )

    :ok
  end

  defp revoke_access!(user, timestamp) do
    sessions =
      from(session in Session,
        where:
          session.tenant_id == ^user.tenant_id and session.user_id == ^user.id and
            is_nil(session.revoked_at)
      )

    session_ids = sessions |> select([session], session.id) |> Repo.all()
    Repo.update_all(sessions, set: [revoked_at: timestamp, updated_at: timestamp])

    from(device in Device,
      where:
        device.tenant_id == ^user.tenant_id and device.user_id == ^user.id and
          is_nil(device.revoked_at)
    )
    |> Repo.update_all(set: [revoked_at: timestamp, updated_at: timestamp])

    NotificationCommand.user_access_revoked(user.tenant_id, user.id, "password_recovery")
    |> NotificationPort.execute()
    |> notification_ok!()

    audio_revocation_ok!(AudioCalls.revoke_for_user(user.tenant_id, user.id, "password_recovery"))

    session_ids
  end

  defp audio_revocation_ok!({:ok, _count}), do: :ok
  defp audio_revocation_ok!({:error, reason}), do: Repo.rollback(reason)

  defp notification_receipt_or_rollback({:ok, %NotificationReceipt{} = receipt}), do: receipt
  defp notification_receipt_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp notification_receipt_or_rollback(_unexpected),
    do: Repo.rollback(:notification_delivery_unavailable)

  defp notification_ok!(:ok), do: :ok
  defp notification_ok!({:error, reason}), do: Repo.rollback(reason)
  defp notification_ok!(_unexpected), do: Repo.rollback(:notification_delivery_unavailable)

  defp dummy_work(key_result, tenant_slug, email) do
    key =
      case key_result do
        {:ok, configured} -> configured
        _ -> :crypto.hash(:sha256, "unconfigured-password-recovery-key")
      end

    _ = :crypto.mac(:hmac, :sha256, key, "#{tenant_slug}:#{email}")
    _ = Password.hash("password-recovery-dummy-work")
    :ok
  end

  defp dummy_database_work do
    _ = Ecto.Adapters.SQL.query(Repo, "SELECT 1", [])
    :ok
  end

  defp pad_public_response(started_at) do
    minimum =
      Application.get_env(:comms_core, :password_recovery_min_response_ms, 500)
      |> min(2_000)
      |> max(0)

    jitter_limit =
      Application.get_env(:comms_core, :password_recovery_jitter_ms, 50)
      |> min(250)
      |> max(0)

    jitter = if jitter_limit == 0, do: 0, else: :rand.uniform(jitter_limit + 1) - 1
    elapsed = System.monotonic_time(:millisecond) - started_at
    remaining = minimum + jitter - elapsed
    if remaining > 0, do: Process.sleep(remaining)
  end

  defp secure_text_equals(expected, actual) when is_binary(expected) and is_binary(actual) do
    expected_digest = :crypto.hash(:sha256, expected)
    actual_digest = :crypto.hash(:sha256, actual)
    :crypto.hash_equals(expected_digest, actual_digest)
  end

  defp secure_text_equals(_, _), do: false

  defp secure_digest_equals(expected_digest, token)
       when is_binary(expected_digest) and is_binary(token) do
    actual_digest = :crypto.hash(:sha256, token)

    byte_size(expected_digest) == byte_size(actual_digest) and
      :crypto.hash_equals(expected_digest, actual_digest)
  end

  defp secure_digest_equals(_, _), do: false

  defp validate_password(password) do
    if Password.valid_password?(password), do: :ok, else: {:error, :weak_password}
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp audit_or_rollback({:ok, event}), do: event
  defp audit_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp normalized_text(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalized_text(_value), do: ""
  defp normalized_email(value), do: normalized_text(value)

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, found} -> found
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
