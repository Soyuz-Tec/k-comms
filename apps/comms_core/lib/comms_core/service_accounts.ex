defmodule CommsCore.ServiceAccounts do
  import Ecto.Query

  alias CommsCore.{AdmissionQuotas, Conversations, Messaging, Repo}
  alias CommsCore.Accounts.{Device, Session, Tenant}
  alias CommsCore.Audit.AuditEvent
  alias CommsCore.Conversations.{Conversation, Membership}
  alias CommsCore.Messaging.Message
  alias CommsCore.ServiceAccounts.{ServiceAccount, ServiceUser}

  @default_expiry_seconds 90 * 24 * 60 * 60
  @maximum_expiry_seconds 365 * 24 * 60 * 60
  @minimum_expiry_seconds 5 * 60
  @expiration_batch 100
  @dummy_id "00000000-0000-0000-0000-000000000000"
  @dummy_hash :crypto.hash(:sha256, "k-comms-service-account-dummy-secret")

  def create(attrs, subject) when is_map(attrs) and is_map(subject) do
    with {:ok, name} <- valid_name(value(attrs, :name)),
         {:ok, scopes} <- valid_scopes(value(attrs, :scopes)),
         {:ok, expires_at} <- valid_expiry(value(attrs, :expires_at)),
         {:ok, reason} <- required_reason(attrs),
         :ok <- authorize_admin(subject) do
      account_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      device_id = Ecto.UUID.generate()
      {credential, secret_hash, secret_hint, prefix} = credential(account_id)
      timestamp = now()

      Repo.transaction(fn ->
        authorize_admin!(subject)
        quota_ok!(AdmissionQuotas.ensure_active_user_capacity(value(subject, :tenant_id)))

        user =
          %ServiceUser{id: user_id}
          |> ServiceUser.service_changeset(%{
            tenant_id: value(subject, :tenant_id),
            external_subject: "service:#{account_id}",
            display_name: name,
            email: "#{account_id}@service.invalid",
            role: :member,
            status: :active,
            account_type: :service
          })
          |> insert_or_rollback()

        device =
          %Device{id: device_id}
          |> Device.changeset(%{
            tenant_id: value(subject, :tenant_id),
            user_id: user.id,
            name: "#{name} credential",
            platform: "service_account"
          })
          |> insert_or_rollback()

        account =
          %ServiceAccount{id: account_id}
          |> ServiceAccount.changeset(%{
            tenant_id: value(subject, :tenant_id),
            user_id: user.id,
            device_id: device.id,
            created_by_user_id: value(subject, :user_id),
            name: name,
            credential_prefix: prefix,
            secret_hash: secret_hash,
            secret_hint: secret_hint,
            scopes: scopes,
            status: :active,
            expires_at: expires_at,
            last_rotated_at: timestamp,
            credential_generation: 1,
            lock_version: 1
          })
          |> insert_or_rollback()

        insert_audit!(subject, "service_account.create", account.id, %{
          name: name,
          scopes: scopes,
          expires_at: expires_at,
          reason: reason
        })

        %{service_account: account, credential: credential}
      end)
      |> transaction_result()
    end
  end

  def create(_, _), do: {:error, :forbidden}

  def list(subject) when is_map(subject) do
    with :ok <- authorize_admin(subject) do
      expire_bounded(value(subject, :tenant_id))

      {:ok,
       ServiceAccount
       |> where([account], account.tenant_id == ^value(subject, :tenant_id))
       |> order_by([account], desc: account.inserted_at, desc: account.id)
       |> Repo.all()}
    end
  end

  def rotate(id, attrs, subject) when is_binary(id) and is_map(attrs) and is_map(subject) do
    with {:ok, id} <- valid_id(id),
         {:ok, expected_version} <- expected_version(attrs),
         {:ok, reason} <- required_reason(attrs),
         :ok <- authorize_admin(subject) do
      expire_bounded(value(subject, :tenant_id))
      {credential, secret_hash, secret_hint, _prefix} = credential(id)

      Repo.transaction(fn ->
        authorize_admin!(subject)
        account = locked_account!(id, subject)
        ensure_active!(account)
        ensure_version!(account, expected_version)

        updated =
          account
          |> ServiceAccount.changeset(%{
            secret_hash: secret_hash,
            secret_hint: secret_hint,
            last_rotated_at: now(),
            credential_generation: account.credential_generation + 1
          })
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        insert_audit!(subject, "service_account.rotate", updated.id, %{
          reason: reason,
          version: updated.lock_version,
          credential_generation: updated.credential_generation
        })

        %{service_account: updated, credential: credential}
      end)
      |> transaction_result()
    end
  end

  def revoke(id, attrs, subject) when is_binary(id) and is_map(attrs) and is_map(subject) do
    with {:ok, id} <- valid_id(id),
         {:ok, expected_version} <- expected_version(attrs),
         {:ok, reason} <- required_reason(attrs),
         :ok <- authorize_admin(subject) do
      expire_bounded(value(subject, :tenant_id))

      Repo.transaction(fn ->
        authorize_admin!(subject)
        account = locked_account!(id, subject)
        ensure_active!(account)
        ensure_version!(account, expected_version)
        timestamp = now()

        updated = disable_account!(account, :revoked, timestamp)

        insert_audit!(subject, "service_account.revoke", updated.id, %{
          reason: reason,
          version: updated.lock_version
        })

        updated
      end)
      |> transaction_result()
    end
  end

  def authenticate(token, request_id \\ nil) do
    {account_id, secret} = parsed_credential(token)
    digest = secret_digest(secret)
    identity = service_identity(account_id)
    expected = if identity, do: elem(identity, 0).secret_hash, else: @dummy_hash
    secret_valid = secure_equals(expected, digest)

    case identity do
      {%ServiceAccount{} = account, %ServiceUser{} = user, %Device{} = device, %Tenant{} = tenant}
      when secret_valid ->
        if active_identity?(account, user, device, tenant) do
          touch_last_used(account)

          {:ok,
           %{
             auth_type: :service,
             service_account_id: account.id,
             credential_generation: account.credential_generation,
             tenant_id: account.tenant_id,
             user_id: account.user_id,
             device_id: account.device_id,
             scopes: account.scopes,
             request_id: request_id
           }}
        else
          {:error, :invalid_service_token}
        end

      _ ->
        {:error, :invalid_service_token}
    end
  end

  def list_conversations(subject) do
    with :ok <- authorize_service(subject, "conversations:read") do
      {:ok,
       subject
       |> Conversations.list_for_user()
       |> Enum.reject(& &1.conversation.archived_at)}
    end
  end

  def list_messages(conversation_id, subject, opts \\ []) when is_binary(conversation_id) do
    with :ok <- authorize_service(subject, "messages:read", conversation_id) do
      Messaging.list_history(
        conversation_id,
        subject,
        Keyword.put(opts, :authorize, &service_authorizer/3)
      )
    end
  end

  def send_message(conversation_id, attrs, subject)
      when is_binary(conversation_id) and is_map(attrs) do
    with :ok <- reject_service_attachments(attrs),
         :ok <- authorize_service(subject, "messages:write", conversation_id) do
      message_attrs =
        attrs
        |> Map.put(:tenant_id, value(subject, :tenant_id))
        |> Map.put(:conversation_id, conversation_id)
        |> Map.put(:sender_user_id, value(subject, :user_id))
        |> Map.put(:sender_device_id, value(subject, :device_id))
        |> Map.put(:attachment_ids, [])

      Messaging.accept_message_with_status(message_attrs, subject,
        authorize: &service_authorizer/3
      )
    end
  end

  def search(query, subject, opts \\ []) when is_binary(query) do
    with :ok <- authorize_service(subject, "search:read") do
      query_text = String.trim(query)

      if query_text == "" do
        {:ok, []}
      else
        limit_count = opts |> Keyword.get(:limit, 50) |> integer(50) |> max(1) |> min(100)

        results =
          Repo.all(
            from(message in Message,
              join: membership in Membership,
              on:
                membership.conversation_id == message.conversation_id and
                  membership.tenant_id == message.tenant_id,
              join: conversation in Conversation,
              on:
                conversation.id == message.conversation_id and
                  conversation.tenant_id == message.tenant_id,
              where:
                message.tenant_id == ^value(subject, :tenant_id) and
                  membership.user_id == ^value(subject, :user_id) and
                  is_nil(membership.left_at) and is_nil(conversation.archived_at) and
                  message.status == :active and
                  fragment(
                    "to_tsvector('simple', coalesce(?, '')) @@ plainto_tsquery('simple', ?)",
                    message.body,
                    ^query_text
                  ),
              order_by: [desc: message.inserted_at],
              limit: ^limit_count,
              preload: [:attachments, :reactions]
            )
          )

        {:ok, results}
      end
    end
  end

  def authorize_service(subject, required_scope, conversation_id \\ nil)

  def authorize_service(subject, required_scope, conversation_id)
      when is_map(subject) and is_binary(required_scope) do
    with true <- value(subject, :auth_type) == :service,
         true <- required_scope in ServiceAccount.scopes(),
         %ServiceAccount{} = account <- current_service_account(subject),
         true <- required_scope in account.scopes,
         :ok <- maybe_authorize_membership(account, conversation_id) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  def authorize_service(_, _, _), do: {:error, :forbidden}

  defp service_authorizer(:send_message, subject, %Conversation{id: id}),
    do: authorize_service(subject, "messages:write", id)

  defp service_authorizer(:read_conversation, subject, %{id: id}),
    do: authorize_service(subject, "messages:read", id)

  defp service_authorizer(_, _, _), do: {:error, :forbidden}

  defp authorize_admin(subject) do
    case human_admin_identity(subject) do
      {%ServiceUser{role: role}, %Session{step_up_at: stepped_up_at}}
      when role in [:owner, :admin] ->
        if recent_step_up?(stepped_up_at), do: :ok, else: {:error, :step_up_required}

      _ ->
        {:error, :forbidden}
    end
  end

  defp authorize_admin!(subject) do
    case authorize_admin(subject) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp human_admin_identity(subject) do
    timestamp = now()

    Repo.one(
      from(user in ServiceUser,
        join: tenant in Tenant,
        on: tenant.id == user.tenant_id,
        join: device in Device,
        on: device.tenant_id == user.tenant_id and device.user_id == user.id,
        join: session in Session,
        on:
          session.tenant_id == user.tenant_id and session.user_id == user.id and
            session.device_id == device.id,
        where:
          user.id == ^value(subject, :user_id) and
            user.tenant_id == ^value(subject, :tenant_id) and
            user.account_type == :human and user.status == :active and
            tenant.status == :active and device.id == ^value(subject, :device_id) and
            is_nil(device.revoked_at) and session.id == ^value(subject, :session_id) and
            is_nil(session.revoked_at) and session.expires_at > ^timestamp,
        select: {user, session}
      )
    )
  end

  defp recent_step_up?(%DateTime{} = stepped_up_at) do
    ttl = Application.get_env(:comms_core, :step_up_ttl_seconds, 300)
    DateTime.compare(stepped_up_at, DateTime.add(now(), -ttl, :second)) in [:eq, :gt]
  end

  defp recent_step_up?(_), do: false

  defp current_service_account(subject) do
    timestamp = now()

    Repo.one(
      from(account in ServiceAccount,
        join: user in ServiceUser,
        on: user.id == account.user_id and user.tenant_id == account.tenant_id,
        join: device in Device,
        on:
          device.id == account.device_id and device.user_id == account.user_id and
            device.tenant_id == account.tenant_id,
        join: tenant in Tenant,
        on: tenant.id == account.tenant_id,
        where:
          account.id == ^value(subject, :service_account_id) and
            account.tenant_id == ^value(subject, :tenant_id) and
            account.user_id == ^value(subject, :user_id) and
            account.device_id == ^value(subject, :device_id) and
            account.credential_generation == ^value(subject, :credential_generation) and
            account.status == :active and account.expires_at > ^timestamp and
            user.account_type == :service and user.status == :active and
            is_nil(user.password_hash) and
            device.platform == "service_account" and is_nil(device.revoked_at) and
            tenant.status == :active,
        select: account
      )
    )
  end

  defp maybe_authorize_membership(_account, nil), do: :ok

  defp maybe_authorize_membership(account, conversation_id) do
    exists =
      Repo.exists?(
        from(membership in Membership,
          join: conversation in Conversation,
          on:
            conversation.id == membership.conversation_id and
              conversation.tenant_id == membership.tenant_id,
          where:
            membership.tenant_id == ^account.tenant_id and
              membership.user_id == ^account.user_id and
              membership.conversation_id == ^conversation_id and is_nil(membership.left_at) and
              is_nil(conversation.archived_at)
        )
      )

    if exists, do: :ok, else: {:error, :forbidden}
  end

  defp service_identity(account_id) do
    Repo.one(
      from(account in ServiceAccount,
        join: user in ServiceUser,
        on: user.id == account.user_id and user.tenant_id == account.tenant_id,
        join: device in Device,
        on:
          device.id == account.device_id and device.user_id == account.user_id and
            device.tenant_id == account.tenant_id,
        join: tenant in Tenant,
        on: tenant.id == account.tenant_id,
        where: account.id == ^account_id,
        select: {account, user, device, tenant}
      )
    )
  end

  defp active_identity?(account, user, device, tenant) do
    account.status == :active and DateTime.compare(account.expires_at, now()) == :gt and
      user.account_type == :service and user.status == :active and is_nil(user.password_hash) and
      user.role == :member and is_nil(user.platform_role) and
      device.platform == "service_account" and is_nil(device.revoked_at) and
      tenant.status == :active
  end

  defp touch_last_used(account) do
    timestamp = now()
    threshold = DateTime.add(timestamp, -60, :second)

    from(candidate in ServiceAccount,
      where:
        candidate.id == ^account.id and candidate.tenant_id == ^account.tenant_id and
          candidate.status == :active and
          (is_nil(candidate.last_used_at) or candidate.last_used_at < ^threshold)
    )
    |> Repo.update_all(set: [last_used_at: timestamp, updated_at: timestamp])

    :ok
  end

  defp expire_bounded(tenant_id) do
    timestamp = now()

    ids =
      ServiceAccount
      |> where(
        [account],
        account.tenant_id == ^tenant_id and account.status == :active and
          account.expires_at <= ^timestamp
      )
      |> order_by([account], asc: account.expires_at)
      |> limit(@expiration_batch)
      |> select([account], account.id)
      |> Repo.all()

    if ids != [] do
      Repo.transaction(fn ->
        Enum.each(ids, fn id ->
          account =
            Repo.one(
              from(candidate in ServiceAccount, where: candidate.id == ^id, lock: "FOR UPDATE")
            )

          if account && account.status == :active &&
               DateTime.compare(account.expires_at, timestamp) != :gt do
            updated = disable_account!(account, :expired, timestamp)

            insert_system_audit!(updated, "service_account.expire", %{
              expires_at: updated.expires_at,
              version: updated.lock_version
            })
          end
        end)
      end)
    end

    :ok
  end

  defp disable_account!(account, status, timestamp) when status in [:revoked, :expired] do
    replacement_hash = :crypto.hash(:sha256, :crypto.strong_rand_bytes(32))

    updated =
      account
      |> ServiceAccount.changeset(%{
        status: status,
        revoked_at: if(status == :revoked, do: timestamp, else: nil),
        secret_hash: replacement_hash,
        secret_hint: random_hint(),
        credential_generation: account.credential_generation + 1
      })
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> update_or_rollback()

    user =
      Repo.one!(
        from(candidate in ServiceUser,
          where: candidate.id == ^account.user_id,
          lock: "FOR UPDATE"
        )
      )

    device =
      Repo.one!(
        from(candidate in Device, where: candidate.id == ^account.device_id, lock: "FOR UPDATE")
      )

    user
    |> Ecto.Changeset.change(%{status: :suspended})
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> update_or_rollback()

    device
    |> Device.changeset(%{revoked_at: timestamp})
    |> update_or_rollback()

    updated
  end

  defp locked_account!(id, subject) do
    Repo.one(
      from(account in ServiceAccount,
        where: account.id == ^id and account.tenant_id == ^value(subject, :tenant_id),
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  defp ensure_active!(%ServiceAccount{status: :active}), do: :ok
  defp ensure_active!(_), do: Repo.rollback(:conflict)

  defp ensure_version!(%ServiceAccount{lock_version: version}, version), do: :ok
  defp ensure_version!(_, _), do: Repo.rollback(:stale_version)

  defp valid_name(name) when is_binary(name) do
    normalized = String.trim(name)
    if String.length(normalized) in 2..120, do: {:ok, normalized}, else: {:error, :invalid_status}
  end

  defp valid_name(_), do: {:error, :invalid_status}

  defp valid_scopes(scopes) when is_list(scopes) do
    normalized = scopes |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.sort()

    if normalized != [] and Enum.all?(normalized, &(&1 in ServiceAccount.scopes())),
      do: {:ok, normalized},
      else: {:error, :invalid_status}
  end

  defp valid_scopes(_), do: {:error, :invalid_status}

  defp valid_expiry(nil), do: {:ok, DateTime.add(now(), @default_expiry_seconds, :second)}
  defp valid_expiry(%DateTime{} = value), do: validate_expiry_bounds(value)

  defp valid_expiry(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> validate_expiry_bounds(datetime)
      _ -> {:error, :invalid_datetime}
    end
  end

  defp valid_expiry(_), do: {:error, :invalid_datetime}

  defp validate_expiry_bounds(value) do
    timestamp = now()
    minimum = DateTime.add(timestamp, @minimum_expiry_seconds, :second)
    maximum = DateTime.add(timestamp, @maximum_expiry_seconds, :second)

    if DateTime.compare(value, minimum) in [:eq, :gt] and
         DateTime.compare(value, maximum) in [:eq, :lt],
       do: {:ok, DateTime.truncate(value, :microsecond)},
       else: {:error, :invalid_datetime}
  end

  defp required_reason(attrs) do
    reason = value(attrs, :reason)
    reason = if is_binary(reason), do: String.trim(reason), else: ""
    if String.length(reason) in 3..1000, do: {:ok, reason}, else: {:error, :reason_required}
  end

  defp expected_version(attrs) do
    case value(attrs, :version) do
      version when is_integer(version) and version > 0 ->
        {:ok, version}

      version when is_binary(version) ->
        case Integer.parse(version) do
          {parsed, ""} when parsed > 0 -> {:ok, parsed}
          _ -> {:error, :version_required}
        end

      _ ->
        {:error, :version_required}
    end
  end

  defp valid_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, :not_found}
    end
  end

  defp reject_service_attachments(attrs) do
    case value(attrs, :attachment_ids) do
      nil -> :ok
      [] -> :ok
      _ -> {:error, :invalid_attachments}
    end
  end

  defp credential(account_id) do
    secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    prefix = "kcsa_#{account_id}"
    {"#{prefix}.#{secret}", secret_digest(secret), String.slice(secret, -4, 4), prefix}
  end

  defp random_hint do
    :crypto.strong_rand_bytes(6)
    |> Base.url_encode64(padding: false)
    |> String.slice(0, 4)
  end

  defp parsed_credential(token) when is_binary(token) and byte_size(token) <= 256 do
    case String.split(token, ".", parts: 2) do
      ["kcsa_" <> id, secret] ->
        with {:ok, normalized_id} <- Ecto.UUID.cast(id),
             {:ok, decoded} <- Base.url_decode64(secret, padding: false),
             true <- byte_size(decoded) == 32 do
          {normalized_id, secret}
        else
          _ -> {@dummy_id, "invalid"}
        end

      _ ->
        {@dummy_id, "invalid"}
    end
  end

  defp parsed_credential(_), do: {@dummy_id, "invalid"}

  defp secret_digest(secret), do: :crypto.hash(:sha256, secret)

  defp secure_equals(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_equals(_, _), do: false

  defp insert_audit!(subject, action, resource_id, metadata) do
    %AuditEvent{}
    |> AuditEvent.changeset(%{
      tenant_id: value(subject, :tenant_id),
      actor_user_id: value(subject, :user_id),
      action: action,
      resource_type: "service_account",
      resource_id: resource_id,
      metadata: metadata,
      request_id: value(subject, :request_id)
    })
    |> insert_or_rollback()
  end

  defp insert_system_audit!(account, action, metadata) do
    %AuditEvent{}
    |> AuditEvent.changeset(%{
      tenant_id: account.tenant_id,
      actor_user_id: nil,
      action: action,
      resource_type: "service_account",
      resource_id: account.id,
      metadata: metadata
    })
    |> insert_or_rollback()
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

  defp quota_ok!(:ok), do: :ok
  defp quota_ok!({:error, reason}), do: Repo.rollback(reason)

  defp transaction_result({:ok, value}), do: {:ok, value}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp integer(value, _) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp integer(_, default), do: default
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
