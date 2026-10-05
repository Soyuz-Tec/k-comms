defmodule CommsCore.Accounts.MatrixSessions do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Accounts, AdmissionQuotas, Repo}

  alias CommsCore.Accounts.{
    MatrixBudget,
    MatrixIdentity,
    MatrixClientSession,
    MatrixIdentityView,
    MatrixClientSessionView,
    MatrixCredentials,
    MatrixProvisioningCommand,
    MatrixProvisioningReceipt,
    MatrixProvisioningPort,
    User
  }

  @max_lease_ms 180_000
  @claim_ms 20_000

  def identity_view(tenant_id, user_id) do
    with {:ok, tenant_id} <- Ecto.UUID.cast(tenant_id),
         {:ok, user_id} <- Ecto.UUID.cast(user_id),
         %MatrixIdentity{} = identity <-
           Repo.one(
             from(i in MatrixIdentity,
               join: u in User,
               on: u.id == i.user_id and u.tenant_id == i.tenant_id,
               where:
                 i.tenant_id == ^tenant_id and i.user_id == ^user_id and i.state == :ready and
                   is_nil(i.erasure_requested_at) and
                   u.status == :active and u.account_type == :human and
                   u.access_scope == :workspace
             )
           ) do
      {:ok,
       %MatrixIdentityView{
         tenant_id: tenant_id,
         user_id: user_id,
         issuer: identity.issuer,
         matrix_user_id: identity.matrix_user_id,
         provisioning_state: :ready
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  # Durable claims commit before external effects. Retrying an unknown result
  # uses the same immutable principal and device, never an unrelated account.
  def client_session(subject), do: client_session(subject, MatrixBudget.new())

  def client_session(subject, deadline) do
    with true <- enabled?() || {:error, :matrix_provisioning_unavailable},
         {:ok, claim} <- claim(subject, deadline) do
      case claim do
        {:cached, view} ->
          {:ok, view}

        {:claimed, identity, session, claim_id, credentials, effect_deadline} ->
          perform(subject, identity, session, claim_id, credentials, effect_deadline)
      end
    end
  end

  def upload_public_signing_keys(keys, subject) when is_map(keys) do
    deadline = MatrixBudget.new()

    with :ok <- validate_signing_keys(keys), {:ok, view} <- client_session(subject, deadline) do
      case MatrixBudget.transaction(deadline, fn ->
             grant = current!(subject, deadline)
             if not grant.step_up_recent?, do: Repo.rollback(:step_up_required)

             identity =
               Repo.get_by!(MatrixIdentity,
                 tenant_id: grant.tenant_id,
                 user_id: grant.user_id,
                 state: :ready
               )

             if Enum.any?(Map.values(keys), &(&1["user_id"] != identity.matrix_user_id)) or
                  view.k_session_id != grant.session_id,
                do: Repo.rollback(:matrix_principal_mismatch)

             auth = open!(identity.auth_secret, identity, %{})

             command = %MatrixProvisioningCommand{
               tenant_id: grant.tenant_id,
               user_id: grant.user_id,
               issuer: identity.issuer,
               matrix_user_id: identity.matrix_user_id,
               matrix_device_id: view.matrix_device_id,
               password: auth["password"],
               access_token: view.access_token,
               deadline: MatrixBudget.authority(deadline, grant),
               public_signing_keys: keys
             }

             case MatrixProvisioningPort.execute(:upload_public_signing_keys, command) do
               {:ok, %MatrixProvisioningReceipt{}} -> :ok
               {:error, reason} -> Repo.rollback(reason)
             end
           end) do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def upload_public_signing_keys(_, _), do: {:error, :invalid_public_signing_keys}

  defp claim(subject, deadline) do
    MatrixBudget.transaction(deadline, fn ->
      grant = current!(subject, deadline)
      deadline = MatrixBudget.authority(deadline, grant)
      MatrixBudget.prepare!(deadline)
      config = config!()

      identity =
        Repo.one(
          from(i in MatrixIdentity,
            where: i.tenant_id == ^grant.tenant_id and i.user_id == ^grant.user_id,
            lock: "FOR UPDATE"
          )
        ) || new_identity!(grant, config)

      if identity.state in [:cleanup_pending, :erased],
        do: Repo.rollback(:matrix_identity_withdrawn)

      if identity.issuer != config.issuer or identity.matrix_user_id != principal(grant, config),
        do: Repo.rollback(:matrix_identity_issuer_changed)

      session =
        Repo.one(
          from(s in MatrixClientSession,
            where: s.tenant_id == ^grant.tenant_id and s.session_id == ^grant.session_id,
            lock: "FOR UPDATE"
          )
        ) || new_session!(grant, identity)

      if session.state in [:cleanup_pending, :revoked],
        do: Repo.rollback(:matrix_device_withdrawn)

      credentials = open!(session.credential_secret, session, %{})

      if (session.state == :ready and session.expires_at) &&
           DateTime.diff(session.expires_at, now(), :millisecond) > 30_000 do
        {:cached, view(identity, session, credentials)}
      else
        if (not is_nil(session.claim_expires_at) and
              DateTime.compare(session.claim_expires_at, now()) == :gt) or
             (not is_nil(identity.claim_expires_at) and
                DateTime.compare(identity.claim_expires_at, now()) == :gt),
           do: Repo.rollback(:matrix_provisioning_busy)

        claim_id = Ecto.UUID.generate()
        expiry = DateTime.add(now(), @claim_ms, :millisecond)

        identity =
          persist_matrix_identity!(identity, claim_id: claim_id, claim_expires_at: expiry)

        session =
          persist_matrix_client_session!(session, claim_id: claim_id, claim_expires_at: expiry)

        {:claimed, identity, session, claim_id, credentials, deadline}
      end
    end)
  end

  defp perform(subject, identity, session, claim_id, credentials, deadline) do
    with {:ok, auth} <- MatrixCredentials.open(identity.auth_secret, identity),
         command = %MatrixProvisioningCommand{
           tenant_id: identity.tenant_id,
           user_id: identity.user_id,
           issuer: identity.issuer,
           matrix_user_id: identity.matrix_user_id,
           deadline: deadline,
           password: auth["password"],
           matrix_device_id: session.matrix_device_id,
           refresh_token: credentials["refresh_token"]
         },
         {:ok, %MatrixProvisioningReceipt{matrix_user_id: user_id}} <-
           MatrixProvisioningPort.execute(:provision, command),
         true <- user_id == identity.matrix_user_id || {:error, :matrix_principal_mismatch},
         {:ok, %MatrixProvisioningReceipt{} = receipt} <-
           MatrixProvisioningPort.execute(
             if(command.refresh_token, do: :refresh, else: :login),
             command
           ),
         :ok <- validate_receipt(receipt, identity, session) do
      finish(subject, identity, session, claim_id, receipt, deadline)
    else
      {:error, reason} ->
        release_claim(identity, session, claim_id)
        {:error, reason}

      _ ->
        release_claim(identity, session, claim_id)
        {:error, :matrix_provider_receipt_invalid}
    end
  end

  defp finish(subject, identity, session, claim_id, receipt, deadline) do
    # This compensation transaction preserves issued credentials/cleanup duties
    # even after the caller budget expired; it never renews caller authority.
    cleanup_deadline = MatrixBudget.new()
    # Persist issued credentials even if the initiating K session withdrew.
    # The separate current-authority transaction can then refuse delivery and
    # mark cleanup pending without losing the provider revocation obligation.
    result =
      MatrixBudget.transaction(cleanup_deadline, fn ->
        AdmissionQuotas.lock_tenant(identity.tenant_id)
        retained_identity = Repo.get!(MatrixIdentity, identity.id)

        retained =
          Repo.one!(
            from(s in MatrixClientSession, where: s.id == ^session.id, lock: "FOR UPDATE")
          )

        if retained.claim_id != claim_id or retained_identity.claim_id != claim_id or
             retained.generation != session.generation or
             retained_identity.generation != identity.generation or
             retained_identity.state in [:cleanup_pending, :erased] or
             not is_nil(retained_identity.erasure_requested_at) or
             retained.state in [:cleanup_pending, :revoked] do
          # Issued credentials remain an exact stable-device cleanup duty, even
          # when the claimant lost authority. Never resurrect the identity.
          secret =
            seal!(
              %{"access_token" => receipt.access_token, "refresh_token" => receipt.refresh_token},
              retained
            )

          persist_matrix_client_session!(retained,
            state: :cleanup_pending,
            credential_secret: secret,
            expires_at: DateTime.add(now(), receipt.expires_in_ms, :millisecond),
            claim_id: nil,
            claim_expires_at: nil
          )

          if retained_identity.claim_id == claim_id,
            do: persist_matrix_identity!(retained_identity, claim_id: nil, claim_expires_at: nil)

          {:stale, :matrix_claim_stale}
        else
          secret =
            seal!(
              %{"access_token" => receipt.access_token, "refresh_token" => receipt.refresh_token},
              retained
            )

          expires_at = DateTime.add(now(), receipt.expires_in_ms, :millisecond)

          retained =
            persist_matrix_client_session!(retained,
              credential_secret: secret,
              expires_at: expires_at,
              state: :ready,
              claim_id: nil,
              claim_expires_at: nil
            )

          retained_identity =
            persist_matrix_identity!(retained_identity,
              state: :ready,
              claim_id: nil,
              claim_expires_at: nil
            )

          {retained_identity, retained}
        end
      end)

    with {:ok, {%MatrixIdentity{} = retained_identity, %MatrixClientSession{} = retained}} <-
           result do
      case MatrixBudget.transaction(deadline, fn ->
             grant = current!(subject, deadline)

             if grant.session_id != retained.session_id or grant.device_id != retained.device_id or
                  grant.user_id != retained.user_id or grant.tenant_id != retained.tenant_id,
                do: Repo.rollback(:forbidden)

             current =
               Repo.one!(
                 from(s in MatrixClientSession, where: s.id == ^retained.id, lock: "FOR SHARE")
               )

             if current.state != :ready, do: Repo.rollback(:matrix_device_withdrawn)
             view(retained_identity, current, open!(current.credential_secret, current, %{}))
           end) do
        {:ok, view} ->
          {:ok, view}

        {:error, reason} ->
          mark_cleanup(retained.id)
          {:error, reason}
      end
    else
      {:ok, {:stale, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp current!(subject, deadline) do
    MatrixBudget.prepare!(deadline)

    with {:ok, tenant} <-
           Ecto.UUID.cast(Map.get(subject, :tenant_id) || Map.get(subject, "tenant_id")),
         {:ok, user} <- Ecto.UUID.cast(Map.get(subject, :user_id) || Map.get(subject, "user_id")),
         {:ok, %{capture_blocked: false}} <-
           CommsCore.Accounts.MatrixAccessProtectionPort.protection(tenant, user) do
      :ok
    else
      _ -> Repo.rollback(:matrix_identity_withdrawn)
    end

    case Accounts.lock_content_write_grant(subject, deadline) do
      {:ok, %{account_type: :human, access_scope: :workspace} = grant} -> grant
      _ -> Repo.rollback(:forbidden)
    end
  end

  defp new_identity!(grant, config) do
    if Repo.aggregate(from(i in MatrixIdentity, where: i.tenant_id == ^grant.tenant_id), :count) >=
         1000,
       do: Repo.rollback(:matrix_identity_capacity_exhausted)

    record = %MatrixIdentity{
      id: Ecto.UUID.generate(),
      tenant_id: grant.tenant_id,
      user_id: grant.user_id,
      issuer: config.issuer,
      matrix_user_id: principal(grant, config),
      generation: 1
    }

    password = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)
    Repo.insert!(%{record | auth_secret: seal!(%{"password" => password}, record)})
  end

  defp new_session!(grant, identity) do
    if Repo.aggregate(
         from(s in MatrixClientSession, where: s.tenant_id == ^grant.tenant_id),
         :count
       ) >= 10_000, do: Repo.rollback(:matrix_device_capacity_exhausted)

    Repo.insert!(%MatrixClientSession{
      tenant_id: grant.tenant_id,
      user_id: grant.user_id,
      device_id: grant.device_id,
      session_id: grant.session_id,
      matrix_identity_id: identity.id,
      matrix_device_id: "KC_" <> String.replace(grant.session_id, "-", "")
    })
  end

  defp release_claim(identity, session, claim_id) do
    Repo.transaction(fn ->
      AdmissionQuotas.lock_tenant(identity.tenant_id)

      Repo.update_all(
        from(i in MatrixIdentity, where: i.id == ^identity.id and i.claim_id == ^claim_id),
        set: [claim_id: nil, claim_expires_at: nil]
      )

      # A timeout may have issued an unacknowledged token. Preserve the exact
      # stable device revocation obligation instead of retrying blindly.
      Repo.update_all(
        from(s in MatrixClientSession, where: s.id == ^session.id and s.claim_id == ^claim_id),
        set: [state: :cleanup_pending, claim_id: nil, claim_expires_at: nil]
      )
    end)
  end

  defp mark_cleanup(id),
    do:
      Repo.update_all(from(s in MatrixClientSession, where: s.id == ^id and s.state == :ready),
        set: [state: :cleanup_pending]
      )

  defp validate_receipt(receipt, identity, session) do
    if receipt.matrix_user_id == identity.matrix_user_id and
         receipt.matrix_device_id == session.matrix_device_id and is_binary(receipt.access_token) and
         byte_size(receipt.access_token) in 1..8192 and is_binary(receipt.refresh_token) and
         byte_size(receipt.refresh_token) in 1..8192 and is_integer(receipt.expires_in_ms) and
         receipt.expires_in_ms in 1000..@max_lease_ms,
       do: :ok,
       else: {:error, :matrix_provider_receipt_invalid}
  end

  defp view(identity, session, credentials),
    do: %MatrixClientSessionView{
      homeserver_url: identity.issuer,
      matrix_user_id: identity.matrix_user_id,
      matrix_device_id: session.matrix_device_id,
      access_token: credentials["access_token"],
      expires_at: session.expires_at,
      k_session_id: session.session_id,
      control_matrix_user_id:
        Application.fetch_env!(:comms_core, :matrix_identity_provider).control_user_id
    }

  defp open!(nil, _record, fallback), do: fallback

  defp open!(secret, record, _fallback) do
    case MatrixCredentials.open(secret, record) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp seal!(value, record) do
    case MatrixCredentials.seal(value, record) do
      {:ok, secret} -> secret
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp principal(grant, config),
    do:
      "@kc_" <>
        String.replace(grant.tenant_id, "-", "") <>
        "_" <> String.replace(grant.user_id, "-", "") <> ":" <> config.server_name

  defp enabled?,
    do: Application.get_env(:comms_core, :matrix_client_provisioning_enabled, false) == true

  defp config! do
    case Application.get_env(:comms_core, :matrix_identity_provider) do
      %{issuer: issuer, server_name: server_name} = config
      when is_binary(issuer) and is_binary(server_name) ->
        config

      _ ->
        Repo.rollback(:matrix_provisioning_unavailable)
    end
  end

  def validate_signing_keys(keys) when is_map(keys) do
    allowed = %{
      "master_key" => "master",
      "self_signing_key" => "self_signing",
      "user_signing_key" => "user_signing"
    }

    if map_size(keys) in 1..3 and byte_size(Jason.encode!(keys)) <= 16_384 and
         Enum.all?(keys, fn {kind, key} ->
           is_map(key) and Map.has_key?(allowed, kind) and
             Enum.all?(Map.keys(key), &(&1 in ["user_id", "usage", "keys", "signatures"])) and
             is_binary(key["user_id"]) and byte_size(key["user_id"]) in 3..512 and
             key["usage"] == [allowed[kind]] and public_ed25519_keys?(key["keys"]) and
             public_signatures?(key["signatures"] || %{})
         end), do: :ok, else: {:error, :invalid_public_signing_keys}
  end

  def validate_signing_keys(_), do: {:error, :invalid_public_signing_keys}

  defp public_ed25519_keys?(keys) when is_map(keys) and map_size(keys) == 1 do
    Enum.all?(keys, fn {name, value} ->
      is_binary(name) and is_binary(value) and String.starts_with?(name, "ed25519:") and
        name == "ed25519:" <> value and base64_size?(value, 32)
    end)
  end

  defp public_ed25519_keys?(_), do: false

  defp public_signatures?(signatures) when is_map(signatures) and map_size(signatures) <= 20 do
    Enum.all?(signatures, fn {user, keys} ->
      is_binary(user) and byte_size(user) in 3..512 and is_map(keys) and map_size(keys) in 1..20 and
        Enum.all?(keys, fn {key, value} ->
          is_binary(key) and byte_size(key) in 9..256 and String.starts_with?(key, "ed25519:") and
            base64_size?(value, 64)
        end)
    end)
  end

  defp public_signatures?(_), do: false

  defp base64_size?(value, expected) when is_binary(value) do
    case Base.decode64(value, padding: false) do
      {:ok, bytes} -> byte_size(bytes) == expected
      _ -> false
    end
  end

  defp base64_size?(_, _), do: false
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  # Durable zero-room barrier: a Matrix identity alone may own encrypted
  # backup versions/cross-signing secrets. Native device revocation cannot
  # prove those and ALL managed client stores have been erased.
  def prepare_erasure(tenant, user) do
    if Repo.in_transaction?() do
      query = %CommsCore.Accounts.MatrixParticipantsLockQuery{
        tenant_id: tenant,
        user_ids: [user],
        deadline: MatrixBudget.new()
      }

      case CommsCore.Accounts.MatrixParticipants.lock(query, nil) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      identities =
        Repo.all(
          from(i in MatrixIdentity,
            where: i.tenant_id == ^tenant and i.user_id == ^user,
            lock: "FOR UPDATE"
          )
        )

      Enum.each(identities, fn identity ->
        generation =
          if(identity.erasure_requested_at,
            do: identity.generation,
            else: identity.generation + 1
          )

        # Envelope associated data includes generation: preserve its integrity
        # when fencing the identity, so native cleanup can still authenticate.
        auth_secret =
          if identity.auth_secret && generation != identity.generation do
            auth = open!(identity.auth_secret, identity, %{})
            seal!(auth, %{identity | generation: generation})
          else
            identity.auth_secret
          end

        persist_matrix_identity!(identity,
          state: :cleanup_pending,
          erasure_requested_at: identity.erasure_requested_at || now(),
          generation: generation,
          auth_secret: auth_secret
        )
      end)

      Repo.update_all(
        from(s in MatrixClientSession,
          where: s.tenant_id == ^tenant and s.user_id == ^user and s.state != :revoked
        ),
        set: [state: :cleanup_pending]
      )

      :ok
    else
      {:error, :transaction_required}
    end
  end

  def erasure_pending?(tenant, user),
    do:
      Repo.exists?(
        from(i in MatrixIdentity,
          where:
            i.tenant_id == ^tenant and i.user_id == ^user and
              (i.key_cleanup_state != "confirmed" or i.state != :erased)
        )
      )

  @doc false
  def revoke_sessions(tenant_id, session_ids) when is_list(session_ids) do
    if Repo.in_transaction?() do
      Repo.update_all(
        from(s in MatrixClientSession,
          where:
            s.tenant_id == ^tenant_id and s.session_id in ^session_ids and
              s.state in [:ready, :pending]
        ),
        set: [state: :cleanup_pending]
      )

      :ok
    else
      {:error, :transaction_required}
    end
  end

  @doc false
  def reconcile(caller) do
    if CommsCore.RuntimePorts.authorized_job_worker?(:matrix_device_reconciler, caller) do
      timestamp = now()

      ids =
        Repo.all(
          from(s in MatrixClientSession,
            join: k in CommsCore.Accounts.Session,
            on: k.id == s.session_id and k.tenant_id == s.tenant_id,
            join: d in CommsCore.Accounts.Device,
            on: d.id == s.device_id and d.tenant_id == s.tenant_id,
            join: u in User,
            on: u.id == s.user_id and u.tenant_id == s.tenant_id,
            where:
              s.state != :revoked and
                (is_nil(s.claim_expires_at) or s.claim_expires_at <= ^timestamp) and
                (s.state == :cleanup_pending or not is_nil(k.revoked_at) or
                   k.expires_at <= ^timestamp or k.absolute_expires_at <= ^timestamp or
                   not is_nil(d.revoked_at) or u.status != :active or u.account_type != :human or
                   u.access_scope != :workspace or
                   (not is_nil(s.claim_expires_at) and s.claim_expires_at <= ^timestamp)),
            order_by: s.inserted_at,
            limit: 50,
            select: s.id
          )
        )

      Enum.reduce_while(ids, {:ok, %{scanned: length(ids), revoked: 0}}, fn id, {:ok, count} ->
        case revoke_device(id) do
          :ok -> {:cont, {:ok, %{count | revoked: count.revoked + 1}}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      {:error, :forbidden}
    end
  end

  defp revoke_device(id) do
    deadline = MatrixBudget.new()

    with {:ok, {identity, session}} <-
           MatrixBudget.transaction(deadline, fn ->
             session = Repo.get!(MatrixClientSession, id)
             AdmissionQuotas.lock_tenant(session.tenant_id)

             session =
               Repo.one!(from(s in MatrixClientSession, where: s.id == ^id, lock: "FOR UPDATE"))

             if session.state == :revoked, do: Repo.rollback(:already_revoked)
             session = persist_matrix_client_session!(session, state: :cleanup_pending)
             {Repo.get!(MatrixIdentity, session.matrix_identity_id), session}
           end),
         {:ok, auth} <- MatrixCredentials.open(identity.auth_secret, identity),
         command = %MatrixProvisioningCommand{
           tenant_id: identity.tenant_id,
           user_id: identity.user_id,
           issuer: identity.issuer,
           matrix_user_id: identity.matrix_user_id,
           deadline: deadline,
           password: auth["password"],
           matrix_device_id: session.matrix_device_id
         },
         {:ok, %MatrixProvisioningReceipt{revoked?: true}} <-
           MatrixProvisioningPort.execute(:revoke, command),
         {:ok, :ok} <-
           MatrixBudget.transaction(deadline, fn ->
             AdmissionQuotas.lock_tenant(session.tenant_id)

             Repo.update_all(
               from(s in MatrixClientSession,
                 where:
                   s.id == ^id and s.state == :cleanup_pending and
                     s.generation == ^session.generation
               ),
               set: [
                 state: :revoked,
                 credential_secret: nil,
                 claim_id: nil,
                 claim_expires_at: nil
               ]
             )

             if not Repo.exists?(
                  from(s in MatrixClientSession,
                    where: s.matrix_identity_id == ^identity.id and s.state != :revoked
                  )
                ) do
               Repo.update_all(
                 from(i in MatrixIdentity,
                   where: i.id == ^identity.id and not is_nil(i.erasure_requested_at)
                 ),
                 set: [auth_secret: nil, claim_id: nil, claim_expires_at: nil]
               )
             end

             :ok
           end) do
      :ok
    else
      {:error, :already_revoked} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_matrix_client_session!(%MatrixClientSession{} = record, attrs),
    do: Repo.update!(MatrixClientSession.retained_changeset(record, attrs))

  defp persist_matrix_identity!(%MatrixIdentity{} = record, attrs),
    do: Repo.update!(MatrixIdentity.retained_changeset(record, attrs))
end
