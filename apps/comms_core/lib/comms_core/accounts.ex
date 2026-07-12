defmodule CommsCore.Accounts do
  import Ecto.Query

  alias CommsCore.Accounts.{Device, Session, Tenant, User}
  alias CommsCore.Audit.AuditEvent
  alias CommsCore.Conversations.{Conversation, Membership}
  alias CommsCore.{Authorization, Repo}
  alias CommsCore.Security.Password

  @session_bytes 32

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

  def create_user(attrs, subject) when is_map(attrs) and is_map(subject) do
    tenant_id = value(subject, :tenant_id)
    password = value(attrs, :password)
    email = value(attrs, :email) |> to_string() |> String.trim() |> String.downcase()
    user_id = Ecto.UUID.generate()

    with :ok <- Authorization.authorize(:administer_tenant, subject, %{id: tenant_id}),
         :ok <- validate_password(password) do
      user_changeset =
        User.changeset(%User{id: user_id}, %{
          tenant_id: tenant_id,
          external_subject: value(attrs, :external_subject) || "local:#{email}",
          display_name: value(attrs, :display_name),
          email: email,
          password_hash: Password.hash(password),
          role: assignable_role(value(attrs, :role)),
          status: :active
        })

      audit_changeset =
        AuditEvent.changeset(%AuditEvent{}, %{
          tenant_id: tenant_id,
          actor_user_id: value(subject, :user_id),
          action: "user.create",
          resource_type: "user",
          resource_id: user_id,
          metadata: %{email: email, role: assignable_role(value(attrs, :role))},
          request_id: value(subject, :request_id)
        })

      Ecto.Multi.new()
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
            t.status == :active and u.status == :active and is_nil(d.revoked_at),
        preload: [tenant: t, user: u, device: d]
      )

    case Repo.one(query) do
      %Session{} = session -> {:ok, session}
      nil -> {:error, :session_expired}
    end
  end

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

  def get_user_for_subject(subject) do
    Repo.get_by(User,
      id: value(subject, :user_id),
      tenant_id: value(subject, :tenant_id),
      status: :active
    )
  end

  def subject_for_session(%Session{} = session, request_id \\ nil) do
    session = Repo.preload(session, :user)

    %{
      tenant_id: session.tenant_id,
      user_id: session.user_id,
      device_id: session.device_id,
      session_id: session.id,
      request_id: request_id,
      role: session.user.role
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
         %User{status: :active} = user <-
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

  defp assignable_role(role) when role in [:member, :admin], do: role
  defp assignable_role("admin"), do: :admin
  defp assignable_role(_role), do: :member

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
