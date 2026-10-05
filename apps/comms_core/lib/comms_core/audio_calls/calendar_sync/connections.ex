defmodule CommsCore.AudioCalls.CalendarSync.Connections do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.Accounts.CalendarActorLockQuery
  alias CommsCore.Administration.CalendarPolicyLockQuery

  alias CommsCore.AudioCalls.CalendarSync.{
    AuthorizationReceipt,
    Boxes,
    Budget,
    CallbackCommand,
    Commands,
    Connection,
    ConnectionView,
    EventMapping,
    Export,
    ExternalIdentityReceipt,
    OAuthChallenge,
    OAuthRequest,
    ProtectionPort,
    ProtectionQuery,
    ProviderAdapter,
    SecretContext,
    TokenReceipt,
    SyncCommand
  }

  alias CommsCore.{Accounts, Administration, Audit, Repo}

  def list(subject) do
    with {:ok, tenant, user} <- subject_ids(subject) do
      Budget.transaction(fn deadline ->
        protection = protection!(tenant, nil, [user], deadline)
        query = %{actor_query(subject, deadline, false) | purpose: :cleanup}
        grant = actor!(query)
        policy = policy!(tenant, :cleanup, deadline)

        items =
          Repo.all(
            from(c in Connection,
              where: c.tenant_id == ^tenant and c.user_id == ^user,
              order_by: [asc: c.provider],
              limit: 2
            )
          )

        result = %{
          connections:
            Enum.map(items, fn connection ->
              result = view(connection, policy)

              %{
                result
                | new_exports_allowed?:
                    result.new_exports_allowed? and grant.access_scope == :workspace and
                      not protection.held? and not protection.capture_blocked?
              }
            end),
          policy: policy,
          providers:
            Enum.map([:google, :microsoft], fn provider -> ProviderAdapter.status(provider) end),
          mode: :one_way_hosted_occurrences
        }

        revalidate!(query)
        result
      end)
    end
  end

  def begin(provider, attrs, subject) when provider in [:google, :microsoft] and is_map(attrs) do
    with {:ok, tenant, user} <- subject_ids(subject),
         :ok <- valid_purpose(attrs),
         expected when is_integer(expected) and expected > 0 <-
           value(attrs, :export_policy_version),
         true <- Commands.available?() do
      Budget.transaction(fn deadline ->
        unless ProviderAdapter.status(provider).configured?,
          do: Repo.rollback(:calendar_provider_not_configured)

        cleanup = value(attrs, :purpose) == "cleanup"
        protection = protection!(tenant, nil, [user], deadline)

        if protection.held? or (not cleanup and protection.capture_blocked?),
          do: Repo.rollback(:calendar_export_blocked)

        query = %{
          actor_query(subject, deadline, true)
          | purpose: if(cleanup, do: :cleanup, else: :export)
        }

        grant = actor!(query)
        policy = policy!(tenant, if(cleanup, do: :cleanup, else: :export), deadline)
        unless cleanup or policy.export_allowed?, do: Repo.rollback(:calendar_export_disabled)
        if policy.version != expected, do: Repo.rollback(:stale_version)

        connection =
          Repo.one(
            from(c in Connection,
              where:
                c.tenant_id == ^tenant and
                  c.user_id == ^user and c.provider == ^provider,
              lock: "FOR UPDATE"
            )
          )

        connection =
          if cleanup do
            unless connection && connection.fenced_at && connection.external_identity_box &&
                     connection.status in [
                       :removing,
                       :reauthorization_required,
                       :held_cleanup_blocked
                     ],
                   do: Repo.rollback(:calendar_cleanup_pending)

            connection
          else
            new_challenge_connection!(connection, tenant, user, provider, policy.version)
          end

        Repo.delete_all(from(c in OAuthChallenge, where: c.connection_id == ^connection.id))
        id = Ecto.UUID.generate()
        state = random()
        nonce = random()
        verifier = random() <> random()
        binding = random()
        expires = DateTime.add(Budget.now(), 300, :second)

        box =
          Boxes.encrypt!(
            %{verifier: verifier, nonce: nonce},
            secret_context(connection, id, :challenge)
          )

        Repo.insert!(%OAuthChallenge{
          id: id,
          tenant_id: tenant,
          connection_id: connection.id,
          user_id: user,
          device_id: grant.device_id,
          session_id: grant.session_id,
          provider: provider,
          state_hash: digest(state),
          binding_hash: digest(binding),
          challenge_box: box,
          consent_generation: connection.consent_generation,
          export_policy_version: policy.version,
          expires_at: expires,
          terminal_reason: if(cleanup, do: "cleanup_authorization")
        })

        url =
          case ProviderAdapter.authorization_url(provider, state, nonce, verifier) do
            {:ok, url} when is_binary(url) -> url
            _ -> Repo.rollback(:calendar_provider_not_configured)
          end

        revalidate!(query)
        record!(connection, grant.user_id, "authorization_started")

        %AuthorizationReceipt{
          provider: provider,
          authorization_url: url,
          browser_binding: binding,
          expires_at: expires
        }
      end)
    else
      nil -> {:error, :version_required}
      false -> {:error, :calendar_worker_unavailable}
      {:error, _} = error -> error
      _ -> {:error, :calendar_provider_not_configured}
    end
  end

  def begin(_, _, _), do: {:error, :invalid_calendar_provider}

  defp valid_purpose(attrs) do
    if value(attrs, :purpose) in [nil, "export", "cleanup"],
      do: :ok,
      else: {:error, :invalid_calendar_purpose}
  end

  def callback(%CallbackCommand{} = command) do
    deadline = Budget.deadline()

    with true <-
           command.provider in [:google, :microsoft] and bounded?(command.state, 32, 256) and
             bounded?(command.browser_binding, 32, 256) and bounded?(command.code, 1, 4096),
         %OAuthChallenge{} = initial <-
           Repo.get_by(OAuthChallenge, state_hash: digest(command.state)),
         {:ok, claimed} <-
           Repo.transaction(fn -> claim!(initial, command, deadline) end, timeout: 20_000),
         {:ok, result} <-
           Repo.transaction(fn -> finish!(claimed, command, deadline) end, timeout: 20_000) do
      case result do
        {:rejected, _reason} -> {:error, :calendar_authority_expired}
        %ConnectionView{} = view -> {:ok, view}
      end
    else
      {:error, :calendar_cleanup_principal_mismatch} = error -> error
      {:error, _} -> {:error, :calendar_callback_rejected}
      _ -> {:error, :calendar_callback_rejected}
    end
  end

  def callback(_), do: {:error, :calendar_callback_rejected}

  def unlink(id, attrs, subject) do
    with {:ok, tenant, user} <- subject_ids(subject),
         {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, expected} <- version(attrs) do
      Budget.transaction(fn deadline ->
        protection = protection!(tenant, nil, [user], deadline)
        # The Governance tenant seal is already retained. Assess every current
        # source hold before acquiring identity or connection rows.
        exports =
          Repo.all(
            from(e in Export,
              where: e.tenant_id == ^tenant and e.user_id == ^user and e.connection_id == ^id
            )
          )

        held =
          Enum.reduce(exports, protection.held?, fn export, held ->
            unless export.author_lineage_complete,
              do: Repo.rollback(:calendar_authorship_unavailable)

            source = protection!(tenant, export.conversation_id, export.author_user_ids, deadline)
            held or source.held?
          end)

        query = %{actor_query(subject, deadline, true) | purpose: :cleanup}
        actor!(query)
        policy = policy!(tenant, :cleanup, deadline)
        connection = connection!(tenant, user, id)
        if connection.version != expected, do: Repo.rollback(:stale_version)

        connection =
          if connection.status in [:removed, :removing, :held_cleanup_blocked] and
               not is_nil(connection.fenced_at) do
            connection
          else
            Repo.update!(
              Ecto.Changeset.change(connection,
                fenced_at: connection.fenced_at || Budget.now(),
                status:
                  if(is_nil(connection.credentials_box),
                    do: :removed,
                    else: if(held, do: :held_cleanup_blocked, else: :removing)
                  ),
                credential_destroyed_at:
                  if(is_nil(connection.credentials_box),
                    do: Budget.now(),
                    else: connection.credential_destroyed_at
                  ),
                version: connection.version + 1,
                consent_generation: connection.consent_generation + 1,
                provider_grant_revocation:
                  if(is_nil(connection.credentials_box), do: :confirmed, else: :pending),
                safe_reason: if(held, do: "legal_hold", else: "consent_withdrawn")
              )
            )
          end

        Repo.delete_all(from(c in OAuthChallenge, where: c.connection_id == ^connection.id))

        if connection.status != :removed,
          do: Commands.remove_connection!(connection, "consent_withdrawn")

        revalidate!(query)
        record!(connection, user, "disconnect_requested")
        view(connection, policy)
      end)
    else
      :error -> {:error, :not_found}
      error -> error
    end
  end

  def connection!(tenant, user, id) do
    Repo.one(
      from(c in Connection,
        where: c.id == ^id and c.tenant_id == ^tenant and c.user_id == ^user,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  def view(connection, policy) do
    pending =
      Repo.aggregate(
        from(m in EventMapping, where: m.connection_id == ^connection.id and m.status != :absent),
        :count,
        :id
      )

    %ConnectionView{
      id: connection.id,
      provider: connection.provider,
      version: connection.version,
      status: connection.status,
      consent_generation: connection.consent_generation,
      new_exports_allowed?:
        connection.status == :ready and is_nil(connection.fenced_at) and policy.export_allowed? and
          connection.export_policy_version == policy.version,
      permission_status:
        cond do
          connection.last_success_at -> :verified
          connection.status == :ready -> :scopes_verified
          true -> :unverified
        end,
      provider_grant_revocation: connection.provider_grant_revocation,
      managed_events_pending_removal: pending,
      last_success_at: connection.last_success_at,
      safe_reason: connection.safe_reason
    }
  end

  def secret_context(connection, resource, purpose) do
    %SecretContext{
      tenant_id: connection.tenant_id,
      user_id: connection.user_id,
      provider: connection.provider,
      resource_id: resource,
      generation:
        if(purpose == :challenge,
          do: connection.consent_generation,
          else: connection.credential_generation
        ),
      purpose: purpose
    }
  end

  defp claim!(initial, command, deadline) do
    protection = protection!(initial.tenant_id, nil, [initial.user_id], deadline)

    cleanup = initial.terminal_reason == "cleanup_authorization"

    if protection.held? or (not cleanup and protection.capture_blocked?),
      do: Repo.rollback(:calendar_export_blocked)

    subject = stored_subject(initial)

    query = %{
      actor_query(subject, deadline, true)
      | purpose: if(cleanup, do: :cleanup, else: :export)
    }

    actor!(query)
    policy = policy!(initial.tenant_id, if(cleanup, do: :cleanup, else: :export), deadline)
    unless cleanup or policy.export_allowed?, do: Repo.rollback(:calendar_export_disabled)
    connection = connection!(initial.tenant_id, initial.user_id, initial.connection_id)

    challenge =
      Repo.one(from(c in OAuthChallenge, where: c.id == ^initial.id, lock: "FOR UPDATE")) ||
        Repo.rollback(:calendar_callback_rejected)

    unless challenge.provider == command.provider and is_nil(challenge.consumed_at) and
             challenge.consent_generation == connection.consent_generation and
             challenge.export_policy_version == policy.version and
             ((cleanup and not is_nil(connection.fenced_at) and
                 not is_nil(connection.external_identity_box)) or
                (not cleanup and connection.status == :awaiting_consent and
                   is_nil(connection.fenced_at))) and
             DateTime.compare(challenge.expires_at, Budget.now()) == :gt and
             :crypto.hash_equals(challenge.binding_hash, digest(command.browser_binding)),
           do: Repo.rollback(:calendar_callback_rejected)

    secrets =
      Boxes.decrypt!(
        challenge.challenge_box,
        secret_context(connection, challenge.id, :challenge)
      )

    Repo.update!(
      Ecto.Changeset.change(challenge,
        consumed_at: Budget.now(),
        terminal_reason: "exchange_claimed"
      )
    )

    revalidate!(query)
    %{challenge: challenge, subject: subject, secrets: secrets, cleanup?: cleanup}
  end

  defp finish!(claimed, command, deadline) do
    challenge = claimed.challenge
    protection = protection!(challenge.tenant_id, nil, [challenge.user_id], deadline)

    cleanup = claimed.cleanup?

    if protection.held? or (not cleanup and protection.capture_blocked?),
      do: Repo.rollback(:calendar_export_blocked)

    query = %{
      actor_query(claimed.subject, deadline, true)
      | purpose: if(cleanup, do: :cleanup, else: :export)
    }

    actor!(query)
    policy = policy!(challenge.tenant_id, if(cleanup, do: :cleanup, else: :export), deadline)
    connection = connection!(challenge.tenant_id, challenge.user_id, challenge.connection_id)

    unless (cleanup or policy.export_allowed?) and
             policy.version == challenge.export_policy_version and
             connection.consent_generation == challenge.consent_generation and
             ((cleanup and not is_nil(connection.fenced_at) and
                 not is_nil(connection.external_identity_box)) or
                (not cleanup and connection.status == :awaiting_consent and
                   is_nil(connection.fenced_at))) and
             DateTime.compare(challenge.expires_at, Budget.now()) == :gt,
           do: Repo.rollback(:calendar_callback_rejected)

    request = %OAuthRequest{
      provider: command.provider,
      operation: :exchange,
      code: command.code,
      verifier: claimed.secrets["verifier"],
      nonce: claimed.secrets["nonce"],
      deadline_ms: Budget.network_deadline(deadline)
    }

    tokens =
      case ProviderAdapter.token(request) do
        {:ok,
         %TokenReceipt{provider: provider, identity: %ExternalIdentityReceipt{provider: provider}} =
             tokens}
        when provider == command.provider ->
          tokens

        _ ->
          Repo.rollback(:calendar_callback_rejected)
      end

    Budget.check!(deadline)

    if cleanup do
      old_identity =
        Boxes.decrypt!(
          connection.external_identity_box,
          secret_context(connection, connection.id, :external_identity)
        )

      unless same_principal?(old_identity["external_subject"], tokens.identity.external_subject) and
               same_principal?(old_identity["oidc_subject"], tokens.identity.oidc_subject),
             do: Repo.rollback(:calendar_cleanup_principal_mismatch)
    end

    generation = connection.credential_generation + 1
    encryption_connection = %{connection | credential_generation: generation}

    credentials =
      Boxes.encrypt!(
        %{access_token: tokens.access_token, refresh_token: tokens.refresh_token},
        secret_context(encryption_connection, connection.id, :credential)
      )

    identity =
      Boxes.encrypt!(
        %{
          external_subject: tokens.identity.external_subject,
          oidc_subject: tokens.identity.oidc_subject
        },
        secret_context(encryption_connection, connection.id, :external_identity)
      )

    valid =
      DateTime.compare(challenge.expires_at, Budget.now()) == :gt and
        match?({:ok, _}, Accounts.revalidate_calendar_actor(query))

    connection =
      Repo.update!(
        Ecto.Changeset.change(connection,
          credential_generation: generation,
          credentials_box: credentials,
          external_identity_box: identity,
          access_expires_at: tokens.expires_at,
          status: if(valid and not cleanup, do: :ready, else: :removing),
          fenced_at:
            if(cleanup, do: connection.fenced_at, else: if(valid, do: nil, else: Budget.now())),
          provider_grant_revocation:
            if(valid and not cleanup, do: :not_requested, else: :pending),
          version: connection.version + 1,
          safe_reason: if(valid, do: nil, else: "authority_expired")
        )
      )

    Repo.delete!(Repo.get!(OAuthChallenge, challenge.id))

    if valid do
      if cleanup, do: Commands.remove_connection!(connection, "cleanup_reauthorized")

      record!(
        connection,
        challenge.user_id,
        if(cleanup, do: "cleanup_reauthorized", else: "connected")
      )

      view(connection, policy)
    else
      # The consumed challenge cannot replay. Keep returned tokens cleanup-only
      # after a clock expiry, rather than losing the only narrow revocation key.
      Commands.insert!(connection, nil, :revoke)
      {:rejected, :calendar_authority_expired}
    end
  end

  defp new_challenge_connection!(nil, tenant, user, provider, policy_version),
    do:
      Repo.insert!(%Connection{
        id: Ecto.UUID.generate(),
        tenant_id: tenant,
        user_id: user,
        provider: provider,
        export_policy_version: policy_version
      })

  defp new_challenge_connection!(connection, _tenant, _user, _provider, policy_version) do
    unless connection.status in [:awaiting_consent, :removed] and
             is_nil(connection.credentials_box) and
             connection.provider_grant_revocation in [:not_requested, :confirmed],
           do: Repo.rollback(:calendar_cleanup_pending)

    if Repo.exists?(
         from(m in EventMapping,
           where:
             m.connection_id == ^connection.id and
               (m.status != :absent or is_nil(m.verified_at))
         )
       ) or
         Repo.exists?(
           from(c in SyncCommand,
             where:
               c.connection_id == ^connection.id and
                 c.status in [:queued, :leased, :uncertain, :retryable, :blocked, :failed]
           )
         ),
       do: Repo.rollback(:calendar_cleanup_pending)

    Repo.update!(
      Ecto.Changeset.change(connection,
        status: :awaiting_consent,
        fenced_at: nil,
        credential_destroyed_at: nil,
        consent_generation: connection.consent_generation + 1,
        credential_generation: connection.credential_generation + 1,
        version: connection.version + 1,
        provider_grant_revocation: :not_requested,
        export_policy_version: policy_version,
        safe_reason: nil
      )
    )
  end

  defp protection!(tenant, conversation, authors, deadline) do
    Budget.check!(deadline)

    case ProtectionPort.protection(%ProtectionQuery{
           tenant_id: tenant,
           conversation_id: conversation,
           author_user_ids: Enum.uniq(authors),
           deadline_ms: deadline
         }) do
      {:ok, protection} -> protection
      {:error, _} -> Repo.rollback(:calendar_protection_unavailable)
    end
  end

  defp actor!(query), do: Accounts.lock_calendar_actor(query) |> unwrap!()
  defp revalidate!(query), do: Accounts.revalidate_calendar_actor(query) |> unwrap!()

  defp policy!(tenant, purpose, deadline),
    do:
      Administration.lock_calendar_policy(%CalendarPolicyLockQuery{
        tenant_id: tenant,
        purpose: purpose,
        deadline_ms: deadline
      })
      |> unwrap!()

  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)

  defp actor_query(subject, deadline, step_up),
    do: %CalendarActorLockQuery{
      subject: subject,
      deadline_ms: deadline,
      require_step_up?: step_up
    }

  defp stored_subject(challenge),
    do: %{
      tenant_id: challenge.tenant_id,
      user_id: challenge.user_id,
      device_id: challenge.device_id,
      session_id: challenge.session_id,
      request_id: "calendar-callback"
    }

  defp subject_ids(subject) when is_map(subject) do
    with {:ok, tenant} <- Ecto.UUID.cast(value(subject, :tenant_id)),
         {:ok, user} <- Ecto.UUID.cast(value(subject, :user_id)),
         do: {:ok, tenant, user},
         else: (_ -> {:error, :forbidden})
  end

  defp subject_ids(_), do: {:error, :forbidden}

  defp version(attrs) when is_map(attrs) do
    case value(attrs, :version) do
      nil -> {:error, :version_required}
      version when is_integer(version) and version > 0 -> {:ok, version}
      _ -> {:error, :invalid_version}
    end
  end

  defp version(_), do: {:error, :invalid_version}
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp random, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp digest(value), do: :crypto.hash(:sha256, value)

  defp same_principal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) > 0 and
              byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp same_principal?(_, _), do: false

  defp bounded?(value, min, max),
    do:
      is_binary(value) and byte_size(value) in min..max and
        Regex.match?(~r/\A[\x21-\x7e]+\z/, value)

  defp record!(connection, actor, action) do
    case Audit.record(%{
           tenant_id: connection.tenant_id,
           actor_user_id: actor,
           action: "calendar." <> action,
           resource_type: "calendar_connection",
           resource_id: connection.id,
           metadata: %{
             provider: connection.provider,
             version: connection.version,
             consent_generation: connection.consent_generation
           }
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
