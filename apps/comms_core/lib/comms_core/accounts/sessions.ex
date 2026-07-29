defmodule CommsCore.Accounts.Sessions do
  @moduledoc """
  Owns authentication, session rotation, device/session revocation, step-up,
  and one-time socket-ticket persistence for IdentityAccess.

  `CommsCore.Accounts` remains the stable public facade. This module keeps the
  timing, transaction, row-lock, and revocation semantics behind that facade in
  one cohesive persistence boundary.
  """

  import Ecto.Query

  alias CommsCore.Accounts.{
    AccessControl,
    Device,
    PlatformAccess,
    Session,
    SocketTicket,
    User
  }

  alias CommsCore.{Administration, Repo}
  alias CommsCore.Audit
  alias CommsCore.Security.Password

  @session_bytes 32
  @authentication_failure_floor_ms 500
  @authentication_failure_jitter_ms 50

  def authenticate(tenant_slug, email, password, device_attrs \\ %{}) do
    started_at = System.monotonic_time(:millisecond)
    result = authenticate_identity(tenant_slug, email, password, device_attrs)
    pad_authentication_failure(result, started_at)
    result
  end

  def refresh(token) when is_binary(token) do
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

  @doc false
  def refresh_guest(token) when is_binary(token) do
    with {:ok, session_id, secret} <- parse_refresh_token(token) do
      case Repo.transaction(fn ->
             session =
               Repo.one(
                 from(s in Session,
                   where: s.id == ^session_id,
                   lock: "FOR UPDATE"
                 )
               )

             rotate_guest_refresh_session(session, secret)
           end) do
        {:ok, result} -> result
        {:error, _reason} -> {:error, :invalid_refresh_token}
      end
    else
      _ -> {:error, :invalid_refresh_token}
    end
  end

  def get_active(id) when is_binary(id) do
    with {:ok, session, _tenant} <- active_with_tenant(id) do
      {:ok, session}
    end
  end

  @doc false
  def active_with_tenant(id) when is_binary(id) do
    query =
      from(s in Session,
        join: u in assoc(s, :user),
        join: d in assoc(s, :device),
        where:
          s.id == ^id and is_nil(s.revoked_at) and s.expires_at > ^now() and
            s.absolute_expires_at > ^now() and
            u.status == :active and u.account_type == :human and is_nil(d.revoked_at),
        preload: [user: u, device: d]
      )

    with %Session{} = session <- Repo.one(query),
         {:ok, tenant} <- Administration.active_tenant(session.tenant_id) do
      {:ok, session, tenant}
    else
      _ -> {:error, :session_expired}
    end
  end

  @doc false
  def active_guest_with_tenant(id) when is_binary(id) do
    timestamp = now()

    query =
      from(s in Session,
        join: u in assoc(s, :user),
        join: d in assoc(s, :device),
        where:
          s.id == ^id and s.tenant_id == u.tenant_id and s.user_id == u.id and
            s.tenant_id == d.tenant_id and s.user_id == d.user_id and
            s.device_id == d.id and is_nil(s.revoked_at) and
            s.expires_at > ^timestamp and s.absolute_expires_at > ^timestamp and
            u.status == :active and u.account_type == :guest and
            not is_nil(u.guest_expires_at) and u.guest_expires_at > ^timestamp and
            is_nil(d.revoked_at),
        preload: [user: u, device: d]
      )

    with %Session{} = session <- Repo.one(query),
         {:ok, tenant} <- Administration.active_tenant(session.tenant_id) do
      {:ok, session, tenant}
    else
      _ -> {:error, :session_expired}
    end
  end

  def active_guest_with_tenant(_id), do: {:error, :session_expired}

  def issue_socket_ticket(subject) when is_map(subject) do
    session_id = value(subject, :session_id)

    with {:ok, session} <- get_active(session_id),
         true <- session.tenant_id == value(subject, :tenant_id),
         true <- session.user_id == value(subject, :user_id),
         true <- session.device_id == value(subject, :device_id) do
      issue_socket_ticket_for(session, subject, %{})
    else
      _ -> {:error, :invalid_access_token}
    end
  end

  def issue_guest_socket_ticket(subject) when is_map(subject) do
    session_id = value(subject, :session_id)

    with {:ok, session, _tenant} <- active_guest_with_tenant(session_id),
         true <- session.tenant_id == value(subject, :tenant_id),
         true <- session.user_id == value(subject, :user_id),
         true <- session.device_id == value(subject, :device_id),
         {:ok, access_scope} <- guest_socket_access_scope(subject, session) do
      issue_socket_ticket_for(session, subject, access_scope)
    else
      _ -> {:error, :invalid_access_token}
    end
  end

  def issue_guest_socket_ticket(_subject), do: {:error, :invalid_access_token}

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
          case active_socket_session(record.session_id) do
            {:ok, %Session{} = session} -> session
            _ -> Repo.rollback(:invalid_socket_ticket)
          end

        unless session.tenant_id == record.tenant_id and session.user_id == record.user_id and
                 session.device_id == record.device_id,
               do: Repo.rollback(:invalid_socket_ticket)

        record
        |> SocketTicket.changeset(%{consumed_at: now()})
        |> update_or_rollback()

        subject = socket_subject(session, record.access_scope, "socket-connect")

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

  def revoke(session_id, user_id, effects) do
    Repo.transaction(fn ->
      session =
        Repo.one(
          from(s in Session,
            where: s.id == ^session_id and s.user_id == ^user_id,
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:not_found)

      session |> Session.changeset(%{revoked_at: now()}) |> update_or_rollback()

      effects.revoke_sessions.(session.tenant_id, [session.id], "session_logout")

      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def change_password(attrs, subject, effects) when is_map(attrs) and is_map(subject) do
    case change_password_with_effects(attrs, subject, effects) do
      {:ok, result} -> {:ok, result.user}
      {:error, _} = error -> error
    end
  end

  def change_password_with_effects(attrs, subject, effects)
      when is_map(attrs) and is_map(subject) do
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

        revoked_session_ids = revoke_other_sessions!(subject, effects)
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
                s.tenant_id == ^user.tenant_id and is_nil(s.revoked_at) and
                s.expires_at > ^now() and s.absolute_expires_at > ^now(),
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
    |> preload(user: :platform_role_grant)
    |> Repo.all()
  end

  def revoke_device(device_id, subject, effects) do
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

      timestamp = now()
      device |> Device.changeset(%{revoked_at: timestamp}) |> update_or_rollback()

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
      |> Repo.update_all(set: [revoked_at: timestamp, updated_at: timestamp])

      effects.notify_device_revoked.(device.tenant_id, device.user_id, device.id)
      effects.revoke_device.(device.tenant_id, device.id, "device_revoked")

      insert_audit!(subject, "device.revoke", "device", device.id, %{})
      %{device: device, revoked_session_ids: session_ids}
    end)
    |> transaction_result()
  end

  def revoke_own(session_id, subject, effects) do
    revoke_scoped_session(session_id, value(subject, :user_id), subject, effects)
  end

  def list_user_sessions(user_id, subject) do
    with :ok <- AccessControl.authorize_manage_sessions(subject),
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
       |> preload(user: :platform_role_grant)
       |> Repo.all()}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def admin_revoke(user_id, session_id, attrs, subject, effects) when is_map(attrs) do
    with :ok <- AccessControl.authorize_manage_sessions(subject),
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

        effects.revoke_sessions.(
          target.tenant_id,
          [revoked.id],
          "session_admin_revoked"
        )

        insert_audit!(subject, "session.admin_revoke", "session", session.id, %{
          user_id: target.id,
          reason: reason
        })

        revoked
      end)
      |> transaction_result()
    end
  end

  def subject(%Session{} = session, request_id \\ nil) do
    session = Repo.preload(session, [user: :platform_role_grant], force: true)
    platform_access = PlatformAccess.for_subject(session.user)

    Map.merge(
      %{
        tenant_id: session.tenant_id,
        user_id: session.user_id,
        device_id: session.device_id,
        session_id: session.id,
        request_id: request_id,
        account_type: session.user.account_type,
        access_scope: session.user.access_scope,
        guest_expires_at: session.user.guest_expires_at,
        role: session.user.role,
        step_up_at: session.step_up_at
      },
      platform_access
    )
  end

  @doc false
  def lock_active_guest(subject) do
    timestamp = now()

    case subject_identity(subject) do
      {tenant_id, user_id, device_id, session_id}
      when is_binary(tenant_id) and is_binary(user_id) and is_binary(device_id) and
             is_binary(session_id) ->
        session =
          Repo.one(
            from(s in Session,
              join: u in User,
              on: u.id == s.user_id and u.tenant_id == s.tenant_id,
              join: d in Device,
              on:
                d.id == s.device_id and d.user_id == s.user_id and
                  d.tenant_id == s.tenant_id,
              where:
                s.id == ^session_id and s.tenant_id == ^tenant_id and
                  s.user_id == ^user_id and s.device_id == ^device_id and
                  is_nil(s.revoked_at) and s.expires_at > ^timestamp and
                  s.absolute_expires_at > ^timestamp and u.status == :active and
                  u.account_type == :guest and not is_nil(u.guest_expires_at) and
                  u.guest_expires_at > ^timestamp and is_nil(d.revoked_at),
              preload: [user: u, device: d],
              lock: "FOR UPDATE"
            )
          )

        with %Session{} = session <- session,
             {:ok, tenant} <- Administration.active_tenant(tenant_id) do
          {:ok, session, tenant}
        else
          nil -> {:error, :session_expired}
          {:error, _reason} = error -> error
        end

      _ ->
        {:error, :forbidden}
    end
  end

  @doc false
  def create_or_rollback(user, device) do
    case create(user, device) do
      {:ok, session, refresh_token} -> {session, refresh_token}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc false
  def create_guest_or_rollback(user, device, guest_expires_at, created_at) do
    id = Ecto.UUID.generate()
    {refresh_token, refresh_hash} = new_refresh_token(id)

    expires_at =
      earlier_deadline(
        DateTime.add(created_at, session_ttl_seconds(), :second),
        guest_expires_at
      )

    session =
      %Session{id: id}
      |> Session.changeset(%{
        tenant_id: user.tenant_id,
        user_id: user.id,
        device_id: device.id,
        refresh_token_hash: refresh_hash,
        expires_at: expires_at,
        absolute_expires_at: guest_expires_at,
        last_used_at: created_at
      })
      |> insert_or_rollback()

    {session, refresh_token}
  end

  @doc false
  def new_deadlines(created_at) do
    absolute_expires_at =
      DateTime.add(created_at, session_absolute_ttl_seconds(), :second)

    %{
      absolute_expires_at: absolute_expires_at,
      expires_at:
        earlier_deadline(
          DateTime.add(created_at, session_ttl_seconds(), :second),
          absolute_expires_at
        )
    }
  end

  @doc false
  def new_refresh_token(session_id) do
    secret = :crypto.strong_rand_bytes(@session_bytes)
    encoded = Base.url_encode64(secret, padding: false)
    {"#{session_id}.#{encoded}", :crypto.hash(:sha256, secret)}
  end

  defp authenticate_identity(tenant_slug, email, password, device_attrs) do
    normalized_email = email |> to_string() |> String.trim() |> String.downcase()

    tenant =
      case Administration.active_tenant_by_slug(tenant_slug) do
        {:ok, tenant} -> tenant
        _ -> nil
      end

    user =
      if tenant do
        Repo.one(
          from(u in User,
            where:
              u.tenant_id == ^tenant.id and u.status == :active and
                u.account_type == :human and
                fragment("lower(?)", u.email) == ^normalized_email
          )
        )
      end

    password_hash = if user, do: user.password_hash

    with %{} = tenant <- tenant,
         %User{} = user <- user,
         true <- Password.verify(password, password_hash),
         {:ok, user} <- maybe_upgrade_password_hash(user, password),
         {:ok, active_tenant} <- Administration.active_tenant(tenant.id),
         {:ok, device} <- upsert_device(user, device_attrs),
         {:ok, session, refresh_token} <- create(user, device) do
      {:ok,
       %{
         tenant: active_tenant,
         user: user,
         device: device,
         session: session,
         refresh_token: refresh_token
       }}
    else
      _ ->
        if is_nil(user), do: Password.verify(password, nil)
        {:error, :invalid_credentials}
    end
  end

  defp pad_authentication_failure({:error, :invalid_credentials}, started_at) do
    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    jitter_ms = :rand.uniform(@authentication_failure_jitter_ms + 1) - 1

    Process.sleep(max(@authentication_failure_floor_ms + jitter_ms - elapsed_ms, 0))
  end

  defp pad_authentication_failure(_result, _started_at), do: :ok

  defp maybe_upgrade_password_hash(%User{} = user, password) do
    if Password.needs_rehash?(user.password_hash) do
      upgraded_hash = Password.hash(password)

      from(existing in User,
        where:
          existing.id == ^user.id and existing.tenant_id == ^user.tenant_id and
            existing.password_hash == ^user.password_hash
      )
      |> Repo.update_all(set: [password_hash: upgraded_hash, updated_at: now()])

      {:ok, Repo.get!(User, user.id)}
    else
      {:ok, user}
    end
  end

  defp active_socket_session(id) do
    case active_with_tenant(id) do
      {:ok, session, _tenant} -> {:ok, session}
      _ -> active_guest_with_tenant(id) |> socket_session_result()
    end
  end

  defp socket_session_result({:ok, session, _tenant}), do: {:ok, session}
  defp socket_session_result(_result), do: {:error, :session_expired}

  defp issue_socket_ticket_for(%Session{} = session, subject, access_scope) do
    ticket_id = Ecto.UUID.generate()
    secret = :crypto.strong_rand_bytes(@session_bytes)
    ticket = "#{ticket_id}.#{Base.url_encode64(secret, padding: false)}"
    issued_at = now()

    configured_ttl =
      Application.get_env(:comms_core, :socket_ticket_ttl_seconds, 60) |> min(120) |> max(10)

    ticket_expires_at =
      DateTime.add(issued_at, configured_ttl, :second)
      |> earlier_deadline(session.expires_at)
      |> earlier_deadline(session.absolute_expires_at)
      |> earlier_optional_deadline(socket_scope_deadline(access_scope))

    expires_in = max(DateTime.diff(ticket_expires_at, issued_at, :second), 1)

    Repo.transaction(fn ->
      prune_socket_tickets!()

      %SocketTicket{id: ticket_id}
      |> SocketTicket.changeset(%{
        tenant_id: session.tenant_id,
        user_id: session.user_id,
        device_id: session.device_id,
        session_id: session.id,
        token_hash: :crypto.hash(:sha256, secret),
        access_scope: access_scope,
        expires_at: ticket_expires_at
      })
      |> insert_or_rollback()

      insert_audit!(subject, "socket_ticket.issue", "session", session.id, %{
        ticket_id: ticket_id,
        expires_in: expires_in,
        guest_scoped: map_size(access_scope) > 0
      })

      %{ticket: ticket, expires_in: expires_in}
    end)
    |> transaction_result()
  end

  defp guest_socket_access_scope(subject, %Session{user: %User{} = user} = session) do
    conversation_id = value(subject, :guest_conversation_id)
    admission_id = value(subject, :guest_admission_id)
    history_from_sequence = value(subject, :guest_history_from_sequence)
    claimed_expiry = value(subject, :guest_expires_at)

    with {:ok, _conversation_uuid} <- Ecto.UUID.cast(conversation_id),
         {:ok, _admission_uuid} <- Ecto.UUID.cast(admission_id),
         true <- is_integer(history_from_sequence) and history_from_sequence >= 0,
         {:ok, expiry} <- cast_datetime(claimed_expiry),
         true <- user.account_type == :guest,
         true <- DateTime.compare(expiry, now()) == :gt,
         true <- deadline_not_after?(expiry, user.guest_expires_at),
         true <- deadline_not_after?(expiry, session.expires_at),
         true <- deadline_not_after?(expiry, session.absolute_expires_at) do
      {:ok,
       %{
         "account_type" => "guest",
         "guest_admission_id" => admission_id,
         "guest_conversation_id" => conversation_id,
         "guest_history_from_sequence" => history_from_sequence,
         "guest_expires_at" => DateTime.to_iso8601(expiry)
       }}
    else
      _ -> {:error, :invalid_guest_scope}
    end
  end

  defp socket_subject(
         %Session{user: %User{account_type: :human}} = session,
         scope,
         request_id
       )
       when scope == %{} or is_nil(scope),
       do: subject(session, request_id)

  defp socket_subject(
         %Session{user: %User{account_type: :guest} = user} = session,
         %{
           "account_type" => "guest",
           "guest_admission_id" => admission_id,
           "guest_conversation_id" => conversation_id,
           "guest_history_from_sequence" => history_from_sequence,
           "guest_expires_at" => expiry_text
         },
         request_id
       ) do
    with {:ok, _conversation_uuid} <- Ecto.UUID.cast(conversation_id),
         {:ok, _admission_uuid} <- Ecto.UUID.cast(admission_id),
         true <- is_integer(history_from_sequence) and history_from_sequence >= 0,
         {:ok, expiry} <- cast_datetime(expiry_text),
         true <- DateTime.compare(expiry, now()) == :gt,
         true <- deadline_not_after?(expiry, user.guest_expires_at),
         true <- deadline_not_after?(expiry, session.expires_at),
         true <- deadline_not_after?(expiry, session.absolute_expires_at) do
      session
      |> subject(request_id)
      |> Map.merge(%{
        account_type: :guest,
        guest_admission_id: admission_id,
        guest_conversation_id: conversation_id,
        guest_history_from_sequence: history_from_sequence,
        guest_expires_at: expiry
      })
    else
      _ -> Repo.rollback(:invalid_socket_ticket)
    end
  end

  defp socket_subject(_session, _scope, _request_id),
    do: Repo.rollback(:invalid_socket_ticket)

  defp socket_scope_deadline(%{"account_type" => "guest", "guest_expires_at" => expiry}) do
    case cast_datetime(expiry) do
      {:ok, deadline} -> deadline
      _ -> nil
    end
  end

  defp socket_scope_deadline(_scope), do: nil

  defp deadline_not_after?(%DateTime{} = deadline, %DateTime{} = authority_deadline),
    do: DateTime.compare(deadline, authority_deadline) in [:lt, :eq]

  defp deadline_not_after?(_deadline, _authority_deadline), do: false

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

  defp create(user, device) do
    id = Ecto.UUID.generate()
    {token, hash} = new_refresh_token(id)
    created_at = now()
    deadlines = new_deadlines(created_at)

    changeset =
      Session.changeset(%Session{id: id}, %{
        tenant_id: user.tenant_id,
        user_id: user.id,
        device_id: device.id,
        refresh_token_hash: hash,
        expires_at: deadlines.expires_at,
        absolute_expires_at: deadlines.absolute_expires_at,
        last_used_at: created_at
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
         {:ok, tenant} <- Administration.active_tenant(session.tenant_id) do
      {new_token, new_hash} = new_refresh_token(session.id)

      case session
           |> Session.changeset(%{
             refresh_token_hash: new_hash,
             last_used_at: now(),
             expires_at: rotated_session_expires_at(session.absolute_expires_at)
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

  defp rotate_guest_refresh_session(%Session{} = session, secret) do
    timestamp = now()

    with true <- active_session?(session),
         true <- secure_hash_equals(session.refresh_token_hash, secret),
         %User{status: :active, account_type: :guest, guest_expires_at: %DateTime{} = expiry} =
           user <- Repo.get_by(User, id: session.user_id, tenant_id: session.tenant_id),
         true <- DateTime.compare(expiry, timestamp) == :gt,
         %Device{} = device <-
           Repo.get_by(Device,
             id: session.device_id,
             tenant_id: session.tenant_id,
             user_id: session.user_id
           ),
         true <- is_nil(device.revoked_at),
         {:ok, tenant} <- Administration.active_tenant(session.tenant_id) do
      {new_token, new_hash} = new_refresh_token(session.id)

      case session
           |> Session.changeset(%{
             refresh_token_hash: new_hash,
             last_used_at: timestamp,
             expires_at:
               session.absolute_expires_at
               |> earlier_deadline(expiry)
               |> rotated_session_expires_at()
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

  defp rotate_guest_refresh_session(nil, _secret), do: {:error, :invalid_refresh_token}

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
    current_time = now()

    is_nil(session.revoked_at) and DateTime.compare(session.expires_at, current_time) == :gt and
      DateTime.compare(session.absolute_expires_at, current_time) == :gt
  end

  defp rotated_session_expires_at(absolute_expires_at),
    do: earlier_deadline(DateTime.add(now(), session_ttl_seconds(), :second), absolute_expires_at)

  defp earlier_deadline(first, second) do
    if DateTime.compare(first, second) == :gt, do: second, else: first
  end

  defp earlier_optional_deadline(first, %DateTime{} = second),
    do: earlier_deadline(first, second)

  defp earlier_optional_deadline(first, _second), do: first

  defp session_ttl_seconds,
    do: Application.get_env(:comms_core, :session_ttl_seconds, 2_592_000) |> max(0)

  defp session_absolute_ttl_seconds,
    do: Application.get_env(:comms_core, :session_absolute_ttl_seconds, 2_592_000) |> max(0)

  defp revoke_scoped_session(
         session_id,
         user_id,
         subject,
         effects,
         action \\ "session.revoke"
       ) do
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

      timestamp = now()
      session |> Session.changeset(%{revoked_at: timestamp}) |> update_or_rollback()

      effects.revoke_sessions.(session.tenant_id, [session.id], "session_revoked")

      insert_audit!(subject, action, "session", session.id, %{user_id: user_id})
      session
    end)
    |> transaction_result()
  end

  defp revoke_other_sessions!(subject, effects) do
    query =
      Session
      |> where(
        [s],
        s.tenant_id == ^value(subject, :tenant_id) and s.user_id == ^value(subject, :user_id) and
          s.id != ^value(subject, :session_id) and is_nil(s.revoked_at)
      )

    ids = query |> select([s], s.id) |> Repo.all()
    Repo.update_all(query, set: [revoked_at: now(), updated_at: now()])

    effects.revoke_sessions.(value(subject, :tenant_id), ids, "password_changed")

    ids
  end

  defp validate_password(password) do
    if Password.valid_password?(password), do: :ok, else: {:error, :weak_password}
  end

  defp active_actor(subject) do
    Repo.get_by(User,
      id: value(subject, :user_id),
      tenant_id: value(subject, :tenant_id),
      status: :active,
      account_type: :human,
      access_scope: :workspace
    )
  end

  defp authorize_session_target(%User{role: :owner}, _target), do: :ok

  defp authorize_session_target(
         %User{role: :security_admin},
         %User{role: role}
       )
       when role not in [:owner, :security_admin],
       do: :ok

  defp authorize_session_target(_, _), do: {:error, :forbidden}

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

  defp cast_datetime(%DateTime{} = value),
    do: {:ok, DateTime.truncate(value, :microsecond)}

  defp cast_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> {:ok, DateTime.truncate(parsed, :microsecond)}
      _ -> {:error, :invalid_datetime}
    end
  end

  defp cast_datetime(_value), do: {:error, :invalid_datetime}

  defp subject_identity(subject) do
    {
      value(subject, :tenant_id),
      value(subject, :user_id),
      value(subject, :device_id),
      value(subject, :session_id)
    }
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

  defp insert_audit!(subject, action, resource_type, resource_id, metadata) do
    %{
      tenant_id: value(subject, :tenant_id),
      actor_user_id: value(subject, :user_id),
      action: action,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: metadata,
      request_id: value(subject, :request_id)
    }
    |> Audit.record()
    |> audit_or_rollback()
  end

  defp audit_or_rollback({:ok, event}), do: event
  defp audit_or_rollback({:error, reason}), do: Repo.rollback(reason)

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
