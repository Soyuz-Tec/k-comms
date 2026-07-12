defmodule CommsCore.Accounts do
  import Ecto.Query

  alias CommsCore.Accounts.{Device, Session, SocketTicket, Tenant, User}
  alias CommsCore.Administration.Invitation
  alias CommsCore.Audit.AuditEvent
  alias CommsCore.Conversations.{Conversation, Membership}
  alias CommsCore.Governance.DeletionRequest
  alias CommsCore.{AdmissionQuotas, Authorization, PushSubscriptions, Repo}
  alias CommsCore.Security.Password

  @session_bytes 32
  @bootstrap_lock_key 1_449_769_383
  @platform_roles [:platform_operator, :support_operator, :security_operator]

  def bootstrap_tenant(attrs) when is_map(attrs) do
    with :ok <- validate_password(value(attrs, :password)) do
      now = now()
      tenant_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      device_id = Ecto.UUID.generate()
      conversation_id = Ecto.UUID.generate()
      session_id = Ecto.UUID.generate()
      {refresh_token, refresh_hash} = refresh_token(session_id)

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(
          :tenant,
          Tenant.changeset(%Tenant{id: tenant_id}, %{
            name: value(attrs, :tenant_name),
            slug: value(attrs, :tenant_slug),
            status: :active
          })
        )
        |> Ecto.Multi.insert(
          :user,
          User.changeset(%User{id: user_id}, %{
            tenant_id: tenant_id,
            external_subject: "local:#{String.downcase(value(attrs, :email) || "")}",
            display_name: value(attrs, :display_name),
            email: value(attrs, :email),
            password_hash: Password.hash(value(attrs, :password)),
            account_type: :human,
            role: :owner,
            status: :active
          })
        )
        |> Ecto.Multi.insert(
          :device,
          Device.changeset(%Device{id: device_id}, %{
            tenant_id: tenant_id,
            user_id: user_id,
            name: value(attrs, :device_name) || "Initial browser",
            platform: value(attrs, :device_platform) || "web",
            last_seen_at: now
          })
        )
        |> Ecto.Multi.insert(
          :conversation,
          Conversation.changeset(%Conversation{id: conversation_id}, %{
            tenant_id: tenant_id,
            created_by_user_id: user_id,
            kind: :channel,
            title: "General",
            visibility: :tenant,
            next_sequence: 1
          })
        )
        |> Ecto.Multi.insert(
          :membership,
          Membership.changeset(%Membership{}, %{
            tenant_id: tenant_id,
            conversation_id: conversation_id,
            user_id: user_id,
            role: :owner,
            joined_at: now,
            last_read_sequence: 0
          })
        )
        |> Ecto.Multi.insert(
          :session,
          Session.changeset(%Session{id: session_id}, %{
            tenant_id: tenant_id,
            user_id: user_id,
            device_id: device_id,
            refresh_token_hash: refresh_hash,
            expires_at: expires_at(),
            last_used_at: now
          })
        )
        |> Ecto.Multi.insert(
          :audit,
          AuditEvent.changeset(%AuditEvent{}, %{
            tenant_id: tenant_id,
            actor_user_id: user_id,
            action: "tenant.bootstrap",
            resource_type: "tenant",
            resource_id: tenant_id,
            metadata: %{initial_conversation_id: conversation_id}
          })
        )

      case Repo.transaction(multi) do
        {:ok, result} ->
          {:ok,
           %{
             tenant: result.tenant,
             user: result.user,
             device: result.device,
             session: result.session,
             refresh_token: refresh_token,
             conversation: result.conversation
           }}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Creates the first tenant owner without creating a browser session.

  The operation is serialized in PostgreSQL so a retried release Job is safe.
  Once a tenant exists, only the same normalized tenant slug and owner email are
  accepted as an idempotent retry; a different bootstrap identity fails closed.
  """
  def bootstrap_tenant_once(attrs) when is_map(attrs) do
    password = value(attrs, :password)

    with :ok <- validate_password(password) do
      identity = bootstrap_identity(attrs)
      password_hash = Password.hash(password)

      Repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT pg_advisory_xact_lock($1::bigint)",
          [@bootstrap_lock_key]
        )

        case Repo.get_by(Tenant, slug: identity.tenant_slug) do
          %Tenant{} = tenant ->
            existing_bootstrap(tenant, identity)

          nil ->
            if Repo.exists?(Tenant) do
              Repo.rollback(:bootstrap_identity_conflict)
            else
              create_one_time_bootstrap(attrs, identity, password_hash)
            end
        end
      end)
      |> case do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def create_user(attrs, subject) when is_map(attrs) and is_map(subject) do
    tenant_id = value(subject, :tenant_id)
    password = value(attrs, :password)
    email = value(attrs, :email) |> to_string() |> String.trim() |> String.downcase()
    user_id = Ecto.UUID.generate()

    with :ok <- reject_platform_role_attribute(attrs),
         :ok <- reject_service_account_attribute(attrs),
         {:ok, requested_role} <- requested_role(attrs),
         :ok <- Authorization.authorize(:manage_user_lifecycle, subject, %{id: tenant_id}),
         :ok <- reject_service_identity_email(tenant_id, email),
         :ok <- authorize_role_assignment(subject, requested_role),
         :ok <- validate_password(password) do
      user_changeset =
        User.changeset(%User{id: user_id}, %{
          tenant_id: tenant_id,
          external_subject: value(attrs, :external_subject) || "local:#{email}",
          display_name: value(attrs, :display_name),
          email: email,
          password_hash: Password.hash(password),
          account_type: :human,
          role: requested_role,
          status: :active
        })

      audit_changeset =
        AuditEvent.changeset(%AuditEvent{}, %{
          tenant_id: tenant_id,
          actor_user_id: value(subject, :user_id),
          action: "user.create",
          resource_type: "user",
          resource_id: user_id,
          metadata: %{email: email, role: requested_role},
          request_id: value(subject, :request_id)
        })

      Ecto.Multi.new()
      |> Ecto.Multi.run(:admission_quota, fn _repo, _changes ->
        case AdmissionQuotas.ensure_active_user_capacity(tenant_id) do
          :ok -> {:ok, :admitted}
          {:error, reason} -> {:error, reason}
        end
      end)
      |> Ecto.Multi.insert(:user, user_changeset)
      |> Ecto.Multi.insert(:audit, audit_changeset)
      |> Repo.transaction()
      |> case do
        {:ok, %{user: user}} -> {:ok, user}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  def authenticate(tenant_slug, email, password, device_attrs \\ %{}) do
    normalized_email = email |> to_string() |> String.trim() |> String.downcase()

    query =
      from(u in User,
        join: t in assoc(u, :tenant),
        where:
          t.slug == ^tenant_slug and t.status == :active and u.status == :active and
            u.account_type == :human and
            fragment("lower(?)", u.email) == ^normalized_email,
        preload: [tenant: t]
      )

    with %User{} = user <- Repo.one(query),
         true <- Password.verify(password, user.password_hash),
         {:ok, device} <- upsert_device(user, device_attrs),
         {:ok, session, refresh_token} <- create_session(user, device) do
      {:ok,
       %{
         tenant: user.tenant,
         user: user,
         device: device,
         session: session,
         refresh_token: refresh_token
       }}
    else
      _ -> {:error, :invalid_credentials}
    end
  end

  def refresh_session(token) when is_binary(token) do
    with {:ok, session_id, secret} <- parse_refresh_token(token) do
      case Repo.transaction(fn ->
             session =
               Repo.one(
                 from(s in Session,
                   where: s.id == ^session_id,
                   lock: "FOR UPDATE"
                 )
               )

             rotate_refresh_session(session, secret)
           end) do
        {:ok, result} -> result
        {:error, _reason} -> {:error, :invalid_refresh_token}
      end
    else
      _ -> {:error, :invalid_refresh_token}
    end
  end

  def get_active_session(id) when is_binary(id) do
    query =
      from(s in Session,
        join: t in assoc(s, :tenant),
        join: u in assoc(s, :user),
        join: d in assoc(s, :device),
        where:
          s.id == ^id and is_nil(s.revoked_at) and s.expires_at > ^now() and
            t.status == :active and u.status == :active and u.account_type == :human and
            is_nil(d.revoked_at),
        preload: [tenant: t, user: u, device: d]
      )

    case Repo.one(query) do
      %Session{} = session -> {:ok, session}
      nil -> {:error, :session_expired}
    end
  end

  def issue_socket_ticket(subject) when is_map(subject) do
    session_id = value(subject, :session_id)

    with {:ok, session} <- get_active_session(session_id),
         true <- session.tenant_id == value(subject, :tenant_id),
         true <- session.user_id == value(subject, :user_id),
         true <- session.device_id == value(subject, :device_id) do
      ticket_id = Ecto.UUID.generate()
      secret = :crypto.strong_rand_bytes(@session_bytes)
      ticket = "#{ticket_id}.#{Base.url_encode64(secret, padding: false)}"

      ttl =
        Application.get_env(:comms_core, :socket_ticket_ttl_seconds, 60) |> min(120) |> max(10)

      Repo.transaction(fn ->
        prune_socket_tickets!()

        %SocketTicket{id: ticket_id}
        |> SocketTicket.changeset(%{
          tenant_id: session.tenant_id,
          user_id: session.user_id,
          device_id: session.device_id,
          session_id: session.id,
          token_hash: :crypto.hash(:sha256, secret),
          expires_at: DateTime.add(now(), ttl, :second)
        })
        |> insert_or_rollback()

        insert_audit!(subject, "socket_ticket.issue", "session", session.id, %{
          ticket_id: ticket_id,
          expires_in: ttl
        })

        %{ticket: ticket, expires_in: ttl}
      end)
      |> transaction_result()
    else
      _ -> {:error, :invalid_access_token}
    end
  end

  def consume_socket_ticket(ticket) when is_binary(ticket) do
    with {:ok, ticket_id, secret} <- parse_socket_ticket(ticket) do
      Repo.transaction(fn ->
        record =
          Repo.one(from(t in SocketTicket, where: t.id == ^ticket_id, lock: "FOR UPDATE")) ||
            Repo.rollback(:invalid_socket_ticket)

        unless is_nil(record.consumed_at) and DateTime.compare(record.expires_at, now()) == :gt and
                 secure_hash_equals(record.token_hash, secret),
               do: Repo.rollback(:invalid_socket_ticket)

        session =
          case get_active_session(record.session_id) do
            {:ok, %Session{} = session} -> session
            _ -> Repo.rollback(:invalid_socket_ticket)
          end

        unless session.tenant_id == record.tenant_id and session.user_id == record.user_id and
                 session.device_id == record.device_id,
               do: Repo.rollback(:invalid_socket_ticket)

        record
        |> SocketTicket.changeset(%{consumed_at: now()})
        |> update_or_rollback()

        subject = subject_for_session(session, "socket-connect")

        insert_audit!(subject, "socket_ticket.consume", "session", session.id, %{
          ticket_id: record.id
        })

        subject
      end)
      |> transaction_result()
    else
      _ -> {:error, :invalid_socket_ticket}
    end
  end

  def consume_socket_ticket(_ticket), do: {:error, :invalid_socket_ticket}

  def revoke_session(session_id, user_id) do
    query = from(s in Session, where: s.id == ^session_id and s.user_id == ^user_id)

    case Repo.update_all(query, set: [revoked_at: now(), updated_at: now()]) do
      {1, _} -> :ok
      _ -> {:error, :not_found}
    end
  end

  def list_tenant_users(subject) do
    tenant_id = value(subject, :tenant_id)

    User
    |> where([u], u.tenant_id == ^tenant_id and u.status != :deleted)
    |> order_by([u], asc: fragment("lower(?)", u.display_name))
    |> Repo.all()
  end

  def list_admin_users(subject) do
    with :ok <-
           Authorization.authorize(:administer_tenant, subject, %{id: value(subject, :tenant_id)}) do
      {:ok, list_tenant_users(subject)}
    end
  end

  def update_profile(attrs, subject) when is_map(attrs) and is_map(subject) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)

    Repo.transaction(fn ->
      user =
        Repo.one(
          from(u in User,
            where:
              u.id == ^user_id and u.tenant_id == ^tenant_id and u.status == :active and
                u.account_type == :human,
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:not_found)

      changes =
        attrs
        |> Map.take([:display_name, :email, "display_name", "email"])

      updated = user |> User.changeset(changes) |> update_or_rollback()

      insert_audit!(subject, "user.profile_update", "user", user.id, %{
        before: %{display_name: user.display_name, email: user.email},
        after: %{display_name: updated.display_name, email: updated.email}
      })

      updated
    end)
    |> transaction_result()
  end

  def change_password(attrs, subject) when is_map(attrs) and is_map(subject) do
    case change_password_with_effects(attrs, subject) do
      {:ok, result} -> {:ok, result.user}
      {:error, _} = error -> error
    end
  end

  def change_password_with_effects(attrs, subject) when is_map(attrs) and is_map(subject) do
    current_password = value(attrs, :current_password)
    new_password = value(attrs, :new_password)

    with :ok <- validate_password(new_password) do
      Repo.transaction(fn ->
        user =
          Repo.one(
            from(u in User,
              where:
                u.id == ^value(subject, :user_id) and
                  u.tenant_id == ^value(subject, :tenant_id) and u.status == :active and
                  u.account_type == :human,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        unless Password.verify(current_password, user.password_hash),
          do: Repo.rollback(:invalid_current_password)

        updated =
          user
          |> User.changeset(%{password_hash: Password.hash(new_password)})
          |> update_or_rollback()

        revoked_session_ids = revoke_other_sessions!(subject)
        insert_audit!(subject, "user.password_change", "user", user.id, %{})
        %{user: updated, revoked_session_ids: revoked_session_ids}
      end)
      |> transaction_result()
    end
  end

  def step_up(attrs, subject) when is_map(attrs) and is_map(subject) do
    password = value(attrs, :current_password)

    Repo.transaction(fn ->
      user =
        Repo.one(
          from(u in User,
            where:
              u.id == ^value(subject, :user_id) and
                u.tenant_id == ^value(subject, :tenant_id) and u.status == :active and
                u.account_type == :human,
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:not_found)

      unless Password.verify(password, user.password_hash),
        do: Repo.rollback(:invalid_current_password)

      session =
        Repo.one(
          from(s in Session,
            where:
              s.id == ^value(subject, :session_id) and s.user_id == ^user.id and
                s.tenant_id == ^user.tenant_id and is_nil(s.revoked_at) and s.expires_at > ^now(),
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:session_expired)

      stepped_up =
        session
        |> Session.changeset(%{step_up_at: now()})
        |> update_or_rollback()

      insert_audit!(subject, "session.step_up", "session", session.id, %{})
      stepped_up
    end)
    |> transaction_result()
  end

  def list_devices(subject) do
    Device
    |> where(
      [d],
      d.tenant_id == ^value(subject, :tenant_id) and d.user_id == ^value(subject, :user_id)
    )
    |> order_by([d], desc: d.last_seen_at, desc: d.inserted_at)
    |> Repo.all()
  end

  def list_sessions(subject) do
    Session
    |> where(
      [s],
      s.tenant_id == ^value(subject, :tenant_id) and s.user_id == ^value(subject, :user_id)
    )
    |> order_by([s], desc: s.last_used_at)
    |> preload(:user)
    |> Repo.all()
  end

  def revoke_device(device_id, subject) do
    Repo.transaction(fn ->
      device =
        Repo.one(
          from(d in Device,
            where:
              d.id == ^device_id and d.tenant_id == ^value(subject, :tenant_id) and
                d.user_id == ^value(subject, :user_id),
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:not_found)

      now = now()
      device |> Device.changeset(%{revoked_at: now}) |> update_or_rollback()

      session_ids =
        Session
        |> where(
          [s],
          s.tenant_id == ^device.tenant_id and s.user_id == ^device.user_id and
            s.device_id == ^device.id and is_nil(s.revoked_at)
        )
        |> select([s], s.id)
        |> Repo.all()

      Session
      |> where(
        [s],
        s.tenant_id == ^device.tenant_id and s.user_id == ^device.user_id and
          s.device_id == ^device.id and is_nil(s.revoked_at)
      )
      |> Repo.update_all(set: [revoked_at: now, updated_at: now])

      :ok = PushSubscriptions.disable_for_device(device.tenant_id, device.user_id, device.id)

      insert_audit!(subject, "device.revoke", "device", device.id, %{})
      %{device: device, revoked_session_ids: session_ids}
    end)
    |> transaction_result()
  end

  def revoke_own_session(session_id, subject) do
    revoke_scoped_session(session_id, value(subject, :user_id), subject)
  end

  def list_user_sessions(user_id, subject) do
    with :ok <-
           Authorization.authorize(:manage_sessions, subject, %{id: value(subject, :tenant_id)}),
         %User{} = actor <- active_actor(subject),
         %User{} = target <-
           Repo.get_by(User,
             id: user_id,
             tenant_id: value(subject, :tenant_id),
             account_type: :human
           ),
         :ok <- authorize_session_target(actor, target) do
      {:ok,
       Session
       |> where([s], s.tenant_id == ^value(subject, :tenant_id) and s.user_id == ^user_id)
       |> order_by([s], desc: s.last_used_at)
       |> preload(:user)
       |> Repo.all()}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def admin_revoke_session(user_id, session_id, attrs, subject) when is_map(attrs) do
    with :ok <-
           Authorization.authorize(:manage_sessions, subject, %{id: value(subject, :tenant_id)}),
         {:ok, reason} <- required_reason(attrs) do
      Repo.transaction(fn ->
        actor = active_actor(subject) || Repo.rollback(:forbidden)

        target =
          Repo.one(
            from(u in User,
              where:
                u.id == ^user_id and u.tenant_id == ^value(subject, :tenant_id) and
                  u.account_type == :human,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        case authorize_session_target(actor, target) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        session =
          Repo.one(
            from(s in Session,
              where:
                s.id == ^session_id and s.user_id == ^target.id and
                  s.tenant_id == ^target.tenant_id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        revoked =
          session
          |> Session.changeset(%{revoked_at: now()})
          |> update_or_rollback()

        insert_audit!(subject, "session.admin_revoke", "session", session.id, %{
          user_id: target.id,
          reason: reason
        })

        revoked
      end)
      |> transaction_result()
    end
  end

  def change_user(user_id, attrs, subject) when is_map(attrs) and is_map(subject) do
    case change_user_with_effects(user_id, attrs, subject) do
      {:ok, result} -> {:ok, result.user}
      {:error, _} = error -> error
    end
  end

  def change_user_with_effects(user_id, attrs, subject)
      when is_map(attrs) and is_map(subject) do
    tenant_id = value(subject, :tenant_id)

    with :ok <- reject_platform_role_attribute(attrs),
         :ok <- reject_service_account_attribute(attrs),
         :ok <- Authorization.authorize(:manage_user_lifecycle, subject, %{id: tenant_id}),
         {:ok, reason} <- required_reason(attrs),
         {:ok, expected_version} <- expected_version(attrs),
         {:ok, role} <- optional_role(attrs),
         {:ok, status} <- optional_status(attrs) do
      Repo.transaction(fn ->
        quota_ok!(AdmissionQuotas.lock_tenant(tenant_id))
        lock_tenant_users!(tenant_id)

        target =
          Repo.one(
            from(u in User,
              where:
                u.id == ^user_id and u.tenant_id == ^tenant_id and u.status != :deleted and
                  u.account_type == :human,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        if target.lock_version != expected_version, do: Repo.rollback(:stale_version)

        actor =
          Repo.get_by!(User,
            id: value(subject, :user_id),
            tenant_id: tenant_id,
            status: :active,
            account_type: :human
          )

        authorize_user_change!(actor, target, role, status)
        ensure_last_owner!(target, role, status)

        if target.status != :active and status == :active do
          quota_ok!(AdmissionQuotas.ensure_active_user_capacity(tenant_id))
        end

        changes =
          %{}
          |> maybe_put(:role, role)
          |> maybe_put(:status, status)
          |> maybe_put(:display_name, value(attrs, :display_name))

        updated =
          target
          |> User.changeset(changes)
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        revoked_session_ids =
          if updated.status != :active, do: revoke_user_access!(updated), else: []

        insert_audit!(subject, "user.lifecycle_update", "user", target.id, %{
          reason: reason,
          before: %{role: target.role, status: target.status, display_name: target.display_name},
          after: %{role: updated.role, status: updated.status, display_name: updated.display_name}
        })

        %{user: updated, revoked_session_ids: revoked_session_ids}
      end)
      |> transaction_result()
    end
  end

  def create_invitation(attrs, subject) when is_map(attrs) and is_map(subject) do
    tenant_id = value(subject, :tenant_id)
    email = value(attrs, :email) |> to_string() |> String.trim() |> String.downcase()
    idempotency_key = value(attrs, :idempotency_key)

    with {:ok, role} <- requested_role(attrs),
         :ok <- Authorization.authorize(:manage_user_lifecycle, subject, %{id: tenant_id}),
         :ok <- reject_service_identity_email(tenant_id, email),
         :ok <- authorize_role_assignment(subject, role),
         :ok <- expire_pending_invitations(tenant_id, email) do
      case existing_idempotent(Invitation, tenant_id, idempotency_key) do
        %Invitation{} = invitation ->
          {:ok, %{invitation: invitation, token: nil, replayed: true}}

        nil ->
          id = Ecto.UUID.generate()
          {token, token_hash} = one_time_token(id)

          multi =
            Ecto.Multi.new()
            |> Ecto.Multi.insert(
              :invitation,
              Invitation.changeset(%Invitation{id: id}, %{
                tenant_id: tenant_id,
                invited_by_user_id: value(subject, :user_id),
                email: email,
                role: role,
                token_hash: token_hash,
                status: :pending,
                expires_at: invitation_expires_at(),
                idempotency_key: idempotency_key
              })
            )
            |> Ecto.Multi.insert(
              :audit,
              audit_changeset(subject, "invitation.create", "invitation", id, %{
                email: email,
                role: role
              })
            )

          case Repo.transaction(multi) do
            {:ok, %{invitation: invitation}} ->
              {:ok, %{invitation: invitation, token: token, replayed: false}}

            {:error, _step, reason, _changes} ->
              {:error, reason}
          end
      end
    end
  end

  def list_invitations(subject, status \\ nil) do
    with :ok <-
           Authorization.authorize(:administer_tenant, subject, %{id: value(subject, :tenant_id)}),
         :ok <- expire_pending_invitations(value(subject, :tenant_id)) do
      query =
        Invitation
        |> where([i], i.tenant_id == ^value(subject, :tenant_id))
        |> maybe_filter_invitation_status(status)
        |> order_by([i], desc: i.inserted_at)

      {:ok, Repo.all(query)}
    end
  end

  def revoke_invitation(id, attrs, subject) do
    with :ok <-
           Authorization.authorize(:manage_user_lifecycle, subject, %{
             id: value(subject, :tenant_id)
           }),
         {:ok, reason} <- required_reason(attrs),
         {:ok, expected_version} <- expected_version(attrs) do
      Repo.transaction(fn ->
        invitation =
          Repo.one(
            from(i in Invitation,
              where: i.id == ^id and i.tenant_id == ^value(subject, :tenant_id),
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        if invitation.lock_version != expected_version, do: Repo.rollback(:stale_version)
        if invitation.status != :pending, do: Repo.rollback(:invitation_not_pending)

        updated =
          invitation
          |> Invitation.changeset(%{status: :revoked, revoked_at: now()})
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        insert_audit!(subject, "invitation.revoke", "invitation", id, %{
          email: invitation.email,
          reason: reason
        })

        updated
      end)
      |> transaction_result()
    end
  end

  def accept_invitation(attrs) when is_map(attrs) do
    token = value(attrs, :token)
    password = value(attrs, :password)

    with :ok <- validate_password(password),
         {:ok, invitation_id, secret} <- parse_one_time_token(token) do
      case Repo.transaction(fn ->
             accept_locked_invitation(invitation_id, secret, password, attrs)
           end) do
        {:ok, {:error, reason}} -> {:error, reason}
        {:ok, %User{} = user} -> {:ok, user}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def get_user_for_subject(subject) do
    Repo.get_by(User,
      id: value(subject, :user_id),
      tenant_id: value(subject, :tenant_id),
      status: :active
    )
  end

  @doc """
  Grants or revokes a platform role from an authenticated release/console workflow.

  This function is intentionally separate from tenant administration changesets and
  HTTP controllers. It fails closed unless a strong management secret is configured,
  the caller supplies that secret using `:grant_token`, and explicit `:actor` and
  `:reason` evidence is provided. The role update and audit event commit atomically.
  Passing `nil`, `"none"`, or `"revoke"` revokes the current platform role.
  """
  def set_platform_role_from_console(user_id, role, attrs)
      when is_binary(user_id) and is_map(attrs) do
    with {:ok, configured_secret} <- platform_role_management_secret(),
         :ok <-
           verify_platform_role_management_secret(configured_secret, value(attrs, :grant_token)),
         {:ok, platform_role} <- normalize_platform_role(role),
         {:ok, actor} <- required_platform_audit_text(attrs, :actor, 3, 120),
         {:ok, reason} <- required_platform_audit_text(attrs, :reason, 8, 500) do
      Repo.transaction(fn ->
        user =
          Repo.one(
            from(u in User,
              where: u.id == ^user_id and u.status == :active and u.account_type == :human,
              lock: "FOR UPDATE"
            )
          ) ||
            Repo.rollback(:not_found)

        before_role = user.platform_role

        updated =
          user
          |> User.platform_role_changeset(%{platform_role: platform_role})
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        action = if is_nil(platform_role), do: "platform_role.revoke", else: "platform_role.grant"

        %AuditEvent{}
        |> AuditEvent.changeset(%{
          tenant_id: user.tenant_id,
          actor_user_id: nil,
          action: action,
          resource_type: "user",
          resource_id: user.id,
          metadata: %{
            actor: actor,
            reason: reason,
            source: "release_console",
            before: before_role,
            after: platform_role
          }
        })
        |> insert_or_rollback()

        updated
      end)
      |> transaction_result()
    end
  end

  def set_platform_role_from_console(_user_id, _role, _attrs),
    do: {:error, :invalid_platform_role_request}

  def subject_for_session(%Session{} = session, request_id \\ nil) do
    session = Repo.preload(session, :user)

    %{
      tenant_id: session.tenant_id,
      user_id: session.user_id,
      device_id: session.device_id,
      session_id: session.id,
      request_id: request_id,
      role: session.user.role,
      platform_role: session.user.platform_role,
      step_up_at: session.step_up_at
    }
  end

  defp upsert_device(user, attrs) do
    requested_id = value(attrs, :id)

    existing =
      if is_binary(requested_id) do
        Repo.get_by(Device, id: requested_id, tenant_id: user.tenant_id, user_id: user.id)
      end

    changes = %{
      tenant_id: user.tenant_id,
      user_id: user.id,
      name: value(attrs, :name) || "Browser",
      platform: value(attrs, :platform) || "web",
      last_seen_at: now(),
      revoked_at: nil
    }

    case existing do
      %Device{} = device -> device |> Device.changeset(changes) |> Repo.update()
      nil -> %Device{} |> Device.changeset(changes) |> Repo.insert()
    end
  end

  defp create_session(user, device) do
    id = Ecto.UUID.generate()
    {token, hash} = refresh_token(id)

    changeset =
      Session.changeset(%Session{id: id}, %{
        tenant_id: user.tenant_id,
        user_id: user.id,
        device_id: device.id,
        refresh_token_hash: hash,
        expires_at: expires_at(),
        last_used_at: now()
      })

    case Repo.insert(changeset) do
      {:ok, session} -> {:ok, session, token}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rotate_refresh_session(%Session{} = session, secret) do
    with true <- active_session?(session),
         true <- secure_hash_equals(session.refresh_token_hash, secret),
         %User{status: :active, account_type: :human} = user <-
           Repo.get_by(User, id: session.user_id, tenant_id: session.tenant_id),
         %Device{} = device <-
           Repo.get_by(Device,
             id: session.device_id,
             tenant_id: session.tenant_id,
             user_id: session.user_id
           ),
         true <- is_nil(device.revoked_at),
         %Tenant{status: :active} = tenant <- Repo.get(Tenant, session.tenant_id) do
      {new_token, new_hash} = refresh_token(session.id)

      case session
           |> Session.changeset(%{
             refresh_token_hash: new_hash,
             last_used_at: now(),
             expires_at: expires_at()
           })
           |> Repo.update() do
        {:ok, updated} ->
          {:ok,
           %{
             tenant: tenant,
             user: user,
             device: device,
             session: updated,
             refresh_token: new_token
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      _ -> {:error, :invalid_refresh_token}
    end
  end

  defp rotate_refresh_session(nil, _secret), do: {:error, :invalid_refresh_token}

  defp refresh_token(session_id) do
    secret = :crypto.strong_rand_bytes(@session_bytes)
    encoded = Base.url_encode64(secret, padding: false)
    {"#{session_id}.#{encoded}", :crypto.hash(:sha256, secret)}
  end

  defp parse_refresh_token(token) do
    case String.split(token, ".", parts: 2) do
      [session_id, secret_text] ->
        with {:ok, secret} <- Base.url_decode64(secret_text, padding: false),
             {:ok, _} <- Ecto.UUID.cast(session_id) do
          {:ok, session_id, secret}
        else
          _ -> {:error, :invalid}
        end

      _ ->
        {:error, :invalid}
    end
  end

  defp parse_socket_ticket(ticket) do
    case String.split(ticket, ".", parts: 2) do
      [id, encoded] ->
        with {:ok, _uuid} <- Ecto.UUID.cast(id),
             {:ok, secret} <- Base.url_decode64(encoded, padding: false),
             true <- byte_size(secret) == @session_bytes do
          {:ok, id, secret}
        else
          _ -> {:error, :invalid_socket_ticket}
        end

      _ ->
        {:error, :invalid_socket_ticket}
    end
  end

  defp prune_socket_tickets! do
    retention = Application.get_env(:comms_core, :socket_ticket_retention_seconds, 3_600)
    cutoff = DateTime.add(now(), -max(retention, 0), :second)

    stale_ids =
      from(t in SocketTicket,
        where: t.expires_at < ^cutoff or (not is_nil(t.consumed_at) and t.consumed_at < ^cutoff),
        order_by: [asc: t.expires_at],
        limit: 500,
        select: t.id
      )

    Repo.delete_all(from(t in SocketTicket, where: t.id in subquery(stale_ids)))
    :ok
  end

  defp secure_hash_equals(hash, secret) when is_binary(hash) and is_binary(secret) do
    actual = :crypto.hash(:sha256, secret)
    byte_size(actual) == byte_size(hash) and :crypto.hash_equals(actual, hash)
  end

  defp secure_hash_equals(_, _), do: false

  defp active_session?(session) do
    is_nil(session.revoked_at) and DateTime.compare(session.expires_at, now()) == :gt
  end

  defp expires_at do
    ttl = Application.get_env(:comms_core, :session_ttl_seconds, 2_592_000)
    DateTime.add(now(), ttl, :second)
  end

  defp validate_password(password) do
    if Password.valid_password?(password), do: :ok, else: {:error, :weak_password}
  end

  defp create_one_time_bootstrap(attrs, identity, password_hash) do
    now = now()
    tenant_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()
    conversation_id = Ecto.UUID.generate()

    tenant =
      insert_or_rollback(
        Tenant.changeset(%Tenant{id: tenant_id}, %{
          name: value(attrs, :tenant_name),
          slug: identity.tenant_slug,
          status: :active
        })
      )

    user =
      insert_or_rollback(
        User.changeset(%User{id: user_id}, %{
          tenant_id: tenant_id,
          external_subject: "local:#{identity.owner_email}",
          display_name: value(attrs, :display_name),
          email: identity.owner_email,
          password_hash: password_hash,
          account_type: :human,
          role: :owner,
          status: :active
        })
      )

    conversation =
      insert_or_rollback(
        Conversation.changeset(%Conversation{id: conversation_id}, %{
          tenant_id: tenant_id,
          created_by_user_id: user_id,
          kind: :channel,
          title: "General",
          visibility: :tenant,
          next_sequence: 1
        })
      )

    _membership =
      insert_or_rollback(
        Membership.changeset(%Membership{}, %{
          tenant_id: tenant_id,
          conversation_id: conversation_id,
          user_id: user_id,
          role: :owner,
          joined_at: now,
          last_read_sequence: 0
        })
      )

    _audit =
      insert_or_rollback(
        AuditEvent.changeset(%AuditEvent{}, %{
          tenant_id: tenant_id,
          actor_user_id: user_id,
          action: "tenant.bootstrap",
          resource_type: "tenant",
          resource_id: tenant_id,
          metadata: %{initial_conversation_id: conversation_id, source: "release"}
        })
      )

    user = maybe_apply_bootstrap_platform_role!(user)

    %{status: :created, tenant: tenant, user: user, conversation: conversation}
  end

  defp existing_bootstrap(tenant, identity) do
    owner =
      Repo.one(
        from(u in User,
          where:
            u.tenant_id == ^tenant.id and u.role == :owner and u.status == :active and
              fragment("lower(?)", u.email) == ^identity.owner_email,
          limit: 1,
          lock: "FOR UPDATE"
        )
      )

    case owner do
      %User{} = user ->
        conversation =
          Repo.one(
            from(c in Conversation,
              where:
                c.tenant_id == ^tenant.id and c.created_by_user_id == ^user.id and
                  c.kind == :channel and c.title == "General",
              order_by: [asc: c.inserted_at],
              limit: 1
            )
          )

        if conversation do
          user = maybe_apply_bootstrap_platform_role!(user)
          %{status: :existing, tenant: tenant, user: user, conversation: conversation}
        else
          Repo.rollback(:bootstrap_identity_conflict)
        end

      nil ->
        Repo.rollback(:bootstrap_identity_conflict)
    end
  end

  defp bootstrap_identity(attrs) do
    tenant_slug =
      attrs
      |> value(:tenant_slug)
      |> to_string()
      |> String.downcase()
      |> String.trim()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    owner_email =
      attrs
      |> value(:email)
      |> to_string()
      |> String.trim()
      |> String.downcase()

    %{tenant_slug: tenant_slug, owner_email: owner_email}
  end

  defp maybe_apply_bootstrap_platform_role!(%User{} = user) do
    if Application.get_env(:comms_core, :allow_bootstrap_platform_role, false) do
      case normalize_platform_role(Application.get_env(:comms_core, :bootstrap_platform_role)) do
        {:ok, nil} ->
          Repo.rollback(:invalid_bootstrap_platform_role)

        {:ok, role} when role == user.platform_role ->
          user

        {:ok, role} ->
          updated =
            user
            |> User.platform_role_changeset(%{platform_role: role})
            |> Ecto.Changeset.optimistic_lock(:lock_version)
            |> update_or_rollback()

          %AuditEvent{}
          |> AuditEvent.changeset(%{
            tenant_id: user.tenant_id,
            actor_user_id: nil,
            action: "platform_role.bootstrap_grant",
            resource_type: "user",
            resource_id: user.id,
            metadata: %{
              actor: "release_bootstrap",
              reason: "explicit local-proof bootstrap configuration",
              source: "local_proof",
              before: user.platform_role,
              after: role
            }
          })
          |> insert_or_rollback()

          updated

        {:error, _reason} ->
          Repo.rollback(:invalid_bootstrap_platform_role)
      end
    else
      user
    end
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp revoke_scoped_session(session_id, user_id, subject, action \\ "session.revoke") do
    Repo.transaction(fn ->
      session =
        Repo.one(
          from(s in Session,
            where:
              s.id == ^session_id and s.user_id == ^user_id and
                s.tenant_id == ^value(subject, :tenant_id),
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:not_found)

      now = now()
      session |> Session.changeset(%{revoked_at: now}) |> update_or_rollback()
      insert_audit!(subject, action, "session", session.id, %{user_id: user_id})
      session
    end)
    |> transaction_result()
  end

  defp revoke_other_sessions!(subject) do
    query =
      Session
      |> where(
        [s],
        s.tenant_id == ^value(subject, :tenant_id) and s.user_id == ^value(subject, :user_id) and
          s.id != ^value(subject, :session_id) and is_nil(s.revoked_at)
      )

    ids = query |> select([s], s.id) |> Repo.all()
    Repo.update_all(query, set: [revoked_at: now(), updated_at: now()])
    ids
  end

  defp revoke_user_access!(user) do
    timestamp = now()

    session_query =
      Session
      |> where(
        [s],
        s.tenant_id == ^user.tenant_id and s.user_id == ^user.id and is_nil(s.revoked_at)
      )

    session_ids = session_query |> select([s], s.id) |> Repo.all()

    Repo.update_all(session_query, set: [revoked_at: timestamp, updated_at: timestamp])

    Device
    |> where(
      [d],
      d.tenant_id == ^user.tenant_id and d.user_id == ^user.id and is_nil(d.revoked_at)
    )
    |> Repo.update_all(set: [revoked_at: timestamp, updated_at: timestamp])

    :ok = PushSubscriptions.disable_for_user(user.tenant_id, user.id, "user_lifecycle_revoked")

    session_ids
  end

  defp lock_tenant_users!(tenant_id) do
    Repo.all(from(u in User, where: u.tenant_id == ^tenant_id, select: u.id, lock: "FOR UPDATE"))
  end

  defp ensure_last_owner!(%User{role: :owner, status: :active} = target, role, status)
       when role not in [nil, :owner] or status not in [nil, :active] do
    pending_deletions =
      from(r in DeletionRequest,
        where:
          r.tenant_id == ^target.tenant_id and r.target_type == :user and
            r.status in [:approved, :in_progress],
        select: r.subject_user_id
      )

    remaining =
      User
      |> where(
        [u],
        u.tenant_id == ^target.tenant_id and u.id != ^target.id and u.role == :owner and
          u.status == :active and u.id not in subquery(pending_deletions)
      )
      |> Repo.aggregate(:count)

    if remaining == 0, do: Repo.rollback(:last_owner_required)
  end

  defp ensure_last_owner!(_, _, _), do: :ok

  defp authorize_user_change!(%User{role: :owner}, _target, _role, _status), do: :ok

  defp authorize_user_change!(%User{role: :admin}, %User{role: target_role}, role, _status) do
    elevated = [:owner, :admin, :compliance_admin, :security_admin]

    if target_role in elevated or role in elevated,
      do: Repo.rollback(:forbidden),
      else: :ok
  end

  defp authorize_user_change!(_, _, _, _), do: Repo.rollback(:forbidden)

  defp authorize_role_assignment(subject, role)
       when role in [:member, :moderator, :admin, :compliance_admin, :security_admin] do
    case Repo.get_by(User,
           id: value(subject, :user_id),
           tenant_id: value(subject, :tenant_id),
           status: :active
         ) do
      %User{role: :owner} -> :ok
      %User{role: :admin} when role in [:member, :moderator] -> :ok
      _ -> {:error, :forbidden}
    end
  end

  defp authorize_role_assignment(_, _), do: {:error, :invalid_role}

  defp optional_role(attrs) do
    case value(attrs, :role) do
      nil ->
        {:ok, nil}

      role ->
        if normalized = normalize_role(role, nil),
          do: {:ok, normalized},
          else: {:error, :invalid_role}
    end
  end

  defp optional_status(attrs) do
    case value(attrs, :status) do
      nil ->
        {:ok, nil}

      status ->
        if normalized = normalize_enum(status, [:active, :suspended, :deleted]),
          do: {:ok, normalized},
          else: {:error, :invalid_status}
    end
  end

  defp expected_version(attrs) do
    case value(attrs, :version) || value(attrs, :lock_version) do
      version when is_integer(version) and version > 0 ->
        {:ok, version}

      version when is_binary(version) ->
        case Integer.parse(version) do
          {number, ""} when number > 0 -> {:ok, number}
          _ -> {:error, :version_required}
        end

      _ ->
        {:error, :version_required}
    end
  end

  defp normalize_role(role, default),
    do:
      normalize_enum(role, [
        :member,
        :moderator,
        :admin,
        :compliance_admin,
        :security_admin,
        :owner
      ]) || default

  defp requested_role(attrs) do
    case value(attrs, :role) do
      nil ->
        {:ok, :member}

      role ->
        case normalize_role(role, nil) do
          nil -> {:error, :invalid_role}
          normalized -> {:ok, normalized}
        end
    end
  end

  defp normalize_enum(value, allowed) when is_atom(value), do: if(value in allowed, do: value)

  defp normalize_enum(value, allowed) when is_binary(value) do
    Enum.find(allowed, &(Atom.to_string(&1) == value))
  end

  defp normalize_enum(_, _), do: nil

  defp reject_platform_role_attribute(attrs) do
    if Map.has_key?(attrs, :platform_role) or Map.has_key?(attrs, "platform_role"),
      do: {:error, :platform_role_console_only},
      else: :ok
  end

  defp normalize_platform_role(role) when role in [nil, "", "none", "revoke"], do: {:ok, nil}

  defp normalize_platform_role(role) do
    case normalize_enum(role, @platform_roles) do
      nil -> {:error, :invalid_platform_role}
      normalized -> {:ok, normalized}
    end
  end

  defp platform_role_management_secret do
    case Application.get_env(:comms_core, :platform_role_management_secret) do
      secret when is_binary(secret) and byte_size(secret) >= 32 -> {:ok, secret}
      _ -> {:error, :platform_role_management_unavailable}
    end
  end

  defp verify_platform_role_management_secret(configured_secret, provided_secret) do
    provided_secret = if is_binary(provided_secret), do: provided_secret, else: ""

    configured_digest = :crypto.hash(:sha256, configured_secret)
    provided_digest = :crypto.hash(:sha256, provided_secret)

    if :crypto.hash_equals(configured_digest, provided_digest),
      do: :ok,
      else: {:error, :invalid_platform_role_management_secret}
  end

  defp required_platform_audit_text(attrs, key, min_length, max_length) do
    case value(attrs, key) do
      text when is_binary(text) ->
        normalized = String.trim(text)

        if String.length(normalized) in min_length..max_length,
          do: {:ok, normalized},
          else: {:error, :platform_role_audit_context_required}

      _ ->
        {:error, :platform_role_audit_context_required}
    end
  end

  defp required_reason(attrs) do
    case value(attrs, :reason) do
      reason when is_binary(reason) ->
        normalized = String.trim(reason)

        if String.length(normalized) in 3..1_000,
          do: {:ok, normalized},
          else: {:error, :reason_required}

      _ ->
        {:error, :reason_required}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp one_time_token(id) do
    secret = :crypto.strong_rand_bytes(@session_bytes)
    {"#{id}.#{Base.url_encode64(secret, padding: false)}", :crypto.hash(:sha256, secret)}
  end

  defp parse_one_time_token(token) when is_binary(token) do
    case String.split(token, ".", parts: 2) do
      [id, encoded] ->
        with {:ok, _} <- Ecto.UUID.cast(id),
             {:ok, secret} <- Base.url_decode64(encoded, padding: false) do
          {:ok, id, secret}
        else
          _ -> {:error, :invalid_invitation}
        end

      _ ->
        {:error, :invalid_invitation}
    end
  end

  defp parse_one_time_token(_), do: {:error, :invalid_invitation}

  defp invitation_expires_at do
    ttl = Application.get_env(:comms_core, :invitation_ttl_seconds, 604_800)
    DateTime.add(now(), ttl, :second)
  end

  defp accept_locked_invitation(invitation_id, secret, password, attrs) do
    invitation =
      Repo.one(from(i in Invitation, where: i.id == ^invitation_id, lock: "FOR UPDATE")) ||
        Repo.rollback(:invalid_invitation)

    cond do
      invitation.status != :pending ->
        {:error, :invalid_invitation}

      DateTime.compare(invitation.expires_at, now()) != :gt ->
        invitation
        |> Invitation.changeset(%{status: :expired})
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> update_or_rollback()

        {:error, :invalid_invitation}

      not secure_hash_equals(invitation.token_hash, secret) ->
        {:error, :invalid_invitation}

      true ->
        quota_ok!(AdmissionQuotas.ensure_active_user_capacity(invitation.tenant_id))
        {user, reactivated} = create_or_reactivate_invited_user!(invitation, password, attrs)

        invitation
        |> Invitation.changeset(%{
          status: :accepted,
          accepted_user_id: user.id,
          accepted_at: now()
        })
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> update_or_rollback()

        %AuditEvent{}
        |> AuditEvent.changeset(%{
          tenant_id: invitation.tenant_id,
          actor_user_id: user.id,
          action: "invitation.accept",
          resource_type: "invitation",
          resource_id: invitation.id,
          metadata: %{email: invitation.email, role: invitation.role, reactivated: reactivated}
        })
        |> insert_or_rollback()

        user
    end
  end

  defp create_or_reactivate_invited_user!(invitation, password, attrs) do
    existing =
      Repo.one(
        from(user in User,
          where:
            user.tenant_id == ^invitation.tenant_id and user.account_type == :human and
              fragment("lower(?)", user.email) == ^String.downcase(invitation.email),
          lock: "FOR UPDATE"
        )
      )

    case existing do
      nil ->
        user =
          %User{id: Ecto.UUID.generate()}
          |> User.changeset(%{
            tenant_id: invitation.tenant_id,
            external_subject: "local:#{invitation.email}",
            display_name: value(attrs, :display_name),
            email: invitation.email,
            password_hash: Password.hash(password),
            account_type: :human,
            role: invitation.role,
            status: :active
          })
          |> insert_or_rollback()

        {user, false}

      %User{status: :suspended} = user ->
        reactivated =
          user
          |> User.changeset(%{
            display_name: value(attrs, :display_name),
            password_hash: Password.hash(password),
            role: invitation.role,
            status: :active
          })
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        {reactivated, true}

      %User{} ->
        Repo.rollback(:invitation_identity_conflict)
    end
  end

  defp expire_pending_invitations(tenant_id, email \\ nil) do
    query =
      from(i in Invitation,
        where: i.tenant_id == ^tenant_id and i.status == :pending and i.expires_at <= ^now()
      )

    query =
      if is_binary(email),
        do: where(query, [i], fragment("lower(?)", i.email) == ^String.downcase(email)),
        else: query

    Repo.update_all(query, set: [status: :expired, updated_at: now()])
    :ok
  end

  defp existing_idempotent(_schema, _tenant_id, nil), do: nil

  defp existing_idempotent(schema, tenant_id, key) do
    Repo.get_by(schema, tenant_id: tenant_id, idempotency_key: key)
  end

  defp maybe_filter_invitation_status(query, nil), do: query

  defp maybe_filter_invitation_status(query, status) do
    case normalize_enum(status, [:pending, :accepted, :revoked, :expired]) do
      nil -> query
      normalized -> where(query, [i], i.status == ^normalized)
    end
  end

  defp active_actor(subject) do
    Repo.get_by(User,
      id: value(subject, :user_id),
      tenant_id: value(subject, :tenant_id),
      status: :active,
      account_type: :human
    )
  end

  defp reject_service_account_attribute(attrs) do
    if value(attrs, :account_type) in [nil, :human, "human"],
      do: :ok,
      else: {:error, :forbidden}
  end

  defp reject_service_identity_email(tenant_id, email) do
    service_identity? =
      Repo.exists?(
        from(user in User,
          where:
            user.tenant_id == ^tenant_id and user.account_type == :service and
              fragment("lower(?)", user.email) == ^String.downcase(email)
        )
      )

    if service_identity?, do: {:error, :forbidden}, else: :ok
  end

  defp authorize_session_target(%User{role: :owner}, _target), do: :ok

  defp authorize_session_target(
         %User{role: :security_admin},
         %User{role: role}
       )
       when role not in [:owner, :security_admin],
       do: :ok

  defp authorize_session_target(_, _), do: {:error, :forbidden}

  defp audit_changeset(subject, action, resource_type, resource_id, metadata) do
    AuditEvent.changeset(%AuditEvent{}, %{
      tenant_id: value(subject, :tenant_id),
      actor_user_id: value(subject, :user_id),
      action: action,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: metadata,
      request_id: value(subject, :request_id)
    })
  end

  defp insert_audit!(subject, action, resource_type, resource_id, metadata) do
    subject
    |> audit_changeset(action, resource_type, resource_id, metadata)
    |> Repo.insert!()
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp quota_ok!(:ok), do: :ok
  defp quota_ok!({:error, reason}), do: Repo.rollback(reason)

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
