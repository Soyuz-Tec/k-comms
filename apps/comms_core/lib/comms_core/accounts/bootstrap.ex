defmodule CommsCore.Accounts.Bootstrap do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Accounts.{
    Device,
    InitialConversationCommand,
    PlatformGrants,
    Session,
    Sessions,
    User
  }

  alias CommsCore.{Administration, Audit, Repo}
  alias CommsCore.Security.Password

  @bootstrap_lock_key 1_449_769_383

  def tenant_view(attrs, effects) do
    with {:ok, result} <- tenant(attrs, effects) do
      {:ok, CommsCore.Accounts.Projector.authentication(result)}
    end
  end

  def tenant(attrs, effects) when is_map(attrs) and is_map(effects) do
    with :ok <- validate_password(value(attrs, :password)) do
      now = now()
      session_deadlines = Sessions.new_deadlines(now)
      tenant_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      device_id = Ecto.UUID.generate()
      conversation_id = Ecto.UUID.generate()
      session_id = Ecto.UUID.generate()
      {refresh_token, refresh_hash} = Sessions.new_refresh_token(session_id)

      initial_conversation = %InitialConversationCommand{
        id: conversation_id,
        tenant_id: tenant_id,
        owner_user_id: user_id,
        joined_at: now
      }

      multi =
        Ecto.Multi.new()
        |> Administration.append_bootstrap_tenant(
          :tenant,
          %{
            id: tenant_id,
            name: value(attrs, :tenant_name),
            slug: value(attrs, :tenant_slug)
          }
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
        |> then(&effects.append_initial_channel.(&1, :conversation, initial_conversation))
        |> Ecto.Multi.insert(
          :session,
          Session.changeset(%Session{id: session_id}, %{
            tenant_id: tenant_id,
            user_id: user_id,
            device_id: device_id,
            refresh_token_hash: refresh_hash,
            expires_at: session_deadlines.expires_at,
            absolute_expires_at: session_deadlines.absolute_expires_at,
            last_used_at: now
          })
        )
        |> Audit.append(%{
          tenant_id: tenant_id,
          actor_user_id: user_id,
          action: "tenant.bootstrap",
          resource_type: "tenant",
          resource_id: tenant_id,
          metadata: %{initial_conversation_id: conversation_id}
        })

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
  def tenant_once(attrs, effects) when is_map(attrs) and is_map(effects) do
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

        case Administration.get_bootstrap_tenant_by_slug(identity.tenant_slug) do
          %{id: _id} = tenant ->
            existing_bootstrap(tenant, identity, effects)

          nil ->
            if Administration.any_tenant?() do
              Repo.rollback(:bootstrap_identity_conflict)
            else
              create_one_time_bootstrap(attrs, identity, password_hash, effects)
            end
        end
      end)
      |> case do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Deletes one release-qualification tenant after verifying its exact owner marker.

  This bounded lifecycle operation is used only by the one-shot release
  qualifier. TenantAdministration retains the tenant row and cascading-delete
  ownership; IdentityAccess verifies that the expected active owner is the
  tenant's only owner before requesting deletion.
  """
  def delete_release_qualification_tenant(attrs) when is_map(attrs) do
    tenant_slug = value(attrs, :tenant_slug)
    tenant_name = value(attrs, :tenant_name)

    owner_email =
      attrs
      |> value(:email)
      |> to_string()
      |> String.trim()
      |> String.downcase()

    qualification_id =
      case Regex.run(
             ~r/\Ak-comms-qualification-([0-9a-f]{32})\z/,
             to_string(tenant_slug)
           ) do
        [_, id] -> id
        _other -> nil
      end

    expected_name = "K-Comms qualification #{qualification_id}"

    expected_email =
      "k-comms-qualification-owner+#{qualification_id}@example.test"

    if qualification_id && tenant_name == expected_name &&
         owner_email == expected_email do
      Repo.transaction(fn ->
        case Administration.get_bootstrap_tenant_by_slug(tenant_slug) do
          nil ->
            %{status: :absent, tenant_slug: tenant_slug}

          %{id: tenant_id, name: ^tenant_name} = tenant ->
            matching_owner_count =
              Repo.aggregate(
                from(u in User,
                  where:
                    u.tenant_id == ^tenant_id and u.role == :owner and
                      u.status == :active and u.email == ^owner_email
                ),
                :count
              )

            total_owner_count =
              Repo.aggregate(
                from(u in User,
                  where: u.tenant_id == ^tenant_id and u.role == :owner
                ),
                :count
              )

            if matching_owner_count == 1 and total_owner_count == 1 do
              case Administration.delete_release_qualification_tenant(tenant) do
                {:ok, deleted} -> %{status: :deleted, tenant: deleted}
                {:error, reason} -> Repo.rollback(reason)
              end
            else
              Repo.rollback(:qualification_tenant_identity_conflict)
            end

          _tenant ->
            Repo.rollback(:qualification_tenant_identity_conflict)
        end
      end)
      |> case do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :qualification_tenant_identity_conflict}
    end
  end

  def delete_release_qualification_tenant(_attrs),
    do: {:error, :qualification_tenant_identity_conflict}

  defp validate_password(password) do
    if Password.valid_password?(password), do: :ok, else: {:error, :weak_password}
  end

  defp create_one_time_bootstrap(attrs, identity, password_hash, effects) do
    now = now()
    tenant_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()
    conversation_id = Ecto.UUID.generate()

    tenant =
      Administration.create_bootstrap_tenant(%{
        id: tenant_id,
        name: value(attrs, :tenant_name),
        slug: identity.tenant_slug
      })
      |> owner_result_or_rollback()

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
      effects.create_initial_channel.(%InitialConversationCommand{
        id: conversation_id,
        tenant_id: tenant_id,
        owner_user_id: user_id,
        joined_at: now
      })
      |> owner_result_or_rollback()

    _audit =
      Audit.record(%{
        tenant_id: tenant_id,
        actor_user_id: user_id,
        action: "tenant.bootstrap",
        resource_type: "tenant",
        resource_id: tenant_id,
        metadata: %{initial_conversation_id: conversation_id, source: "release"}
      })
      |> audit_or_rollback()

    user = PlatformGrants.maybe_apply_bootstrap(user)

    %{status: :created, tenant: tenant, user: user, conversation: conversation}
  end

  defp existing_bootstrap(tenant, identity, effects) do
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
        case effects.fetch_initial_channel.(tenant.id, user.id) do
          {:ok, conversation} when not is_nil(conversation) ->
            user = PlatformGrants.maybe_apply_bootstrap(user)
            %{status: :existing, tenant: tenant, user: user, conversation: conversation}

          {:ok, nil} ->
            Repo.rollback(:bootstrap_identity_conflict)

          {:error, reason} ->
            Repo.rollback(reason)
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

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp audit_or_rollback({:ok, event}), do: event
  defp audit_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp owner_result_or_rollback({:ok, value}), do: value
  defp owner_result_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
