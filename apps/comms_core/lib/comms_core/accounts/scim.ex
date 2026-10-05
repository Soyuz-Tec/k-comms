defmodule CommsCore.Accounts.Scim do
  @moduledoc false
  import Ecto.Query

  alias CommsCore.Accounts.{
    CallLifecycleCommand,
    Directory,
    FederatedIdentity,
    NotificationCommand,
    ScimResource,
    Session,
    User
  }

  alias CommsCore.Accounts.Sessions.Persistence
  alias CommsCore.{AdmissionQuotas, Repo, ServiceAccounts}
  @user_schema "urn:ietf:params:scim:schemas:core:2.0:User"
  @group_schema "urn:ietf:params:scim:schemas:core:2.0:Group"
  @federation_schema "urn:kcomms:params:scim:schemas:extension:federation:2.0:User"

  def configuration(subject) do
    with :ok <- ServiceAccounts.authorize_service(subject, "scim:read") do
      {:ok,
       %{
         schemas: ["urn:ietf:params:scim:schemas:core:2.0:ServiceProviderConfig"],
         patch: %{supported: true},
         bulk: %{supported: false},
         filter: %{supported: true, maxResults: 100},
         changePassword: %{supported: false},
         sort: %{supported: false},
         etag: %{supported: true},
         authenticationSchemes: [
           %{
             type: "oauthbearertoken",
             name: "Tenant scoped service credential",
             description: "Revocable K-Comms service credential",
             primary: true
           }
         ]
       }}
    end
  end

  def list(kind, attrs, subject) when kind in ["User", "Group"] do
    with :ok <- ServiceAccounts.authorize_service(subject, "scim:read"),
         {:ok, start} <- bounded_integer(attrs["startIndex"], 1, 1_000_000),
         {:ok, count} <- bounded_integer(attrs["count"], 100, 100),
         {:ok, filter} <- filter(attrs["filter"]) do
      tenant_id = value(subject, :tenant_id)
      query = from(r in ScimResource, where: r.tenant_id == ^tenant_id and r.kind == ^kind)
      query = if filter, do: where(query, [r], r.external_id == ^filter), else: query
      total = Repo.aggregate(query, :count)

      resources =
        Repo.all(from(r in query, order_by: [asc: r.id], offset: ^(start - 1), limit: ^count))

      {:ok,
       %{
         schemas: ["urn:ietf:params:scim:api:messages:2.0:ListResponse"],
         totalResults: total,
         startIndex: start,
         itemsPerPage: length(resources),
         Resources: Enum.map(resources, &view/1)
       }}
    end
  end

  def get(kind, id, subject) do
    with :ok <- ServiceAccounts.authorize_service(subject, "scim:read"),
         {:ok, id} <- valid_id(id),
         %ScimResource{} = resource <-
           Repo.get_by(ScimResource, id: id, kind: kind, tenant_id: value(subject, :tenant_id)) do
      {:ok, view(resource)}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def create(kind, attrs, subject) when kind in ["User", "Group"] do
    with :ok <- CommsCore.ServiceAccounts.Authentication.preflight(subject, "scim:write"),
         :ok <- reject_authority(attrs),
         true <- Map.get(attrs, "active") in [nil, true, false],
         external_id when is_binary(external_id) and byte_size(external_id) in 1..512 <-
           attrs["externalId"],
         name when is_binary(name) and byte_size(name) in 1..120 <- display_name(attrs) do
      write_transaction(fn deadline ->
        tenant_id = value(subject, :tenant_id)
        policy = locked_policy!(tenant_id)
        authorize_write!(subject, deadline)

        case Repo.get_by(ScimResource, tenant_id: tenant_id, kind: kind, external_id: external_id) do
          %ScimResource{} = existing ->
            if kind == "User" and attrs["userName"] != Repo.get!(User, existing.user_id).email,
              do: Repo.rollback(:scim_identity_conflict)

            view(existing)

          nil ->
            user =
              if kind == "User" do
                case Directory.ensure_active_user_capacity(tenant_id, policy) do
                  :ok -> :ok
                  {:error, reason} -> Repo.rollback(reason)
                end

                status = if attrs["active"] == false, do: :suspended, else: :active
                authorize_write!(subject, deadline)

                %User{}
                |> User.changeset(%{
                  tenant_id: tenant_id,
                  external_subject: "scim:" <> external_id,
                  display_name: name,
                  email: attrs["userName"],
                  account_type: :human,
                  role: :member,
                  status: status
                })
                |> insert!()
              end

            members = members!(kind, attrs["members"], tenant_id)
            authorize_write!(subject, deadline)

            %ScimResource{} =
              resource =
              Repo.insert!(%ScimResource{
                tenant_id: tenant_id,
                user_id: if(user, do: user.id),
                kind: kind,
                external_id: external_id,
                display_name: name,
                members: members
              })

            if user, do: provision_federation!(attrs, user)

            Persistence.insert_audit!(
              subject,
              "identity.scim_provisioned",
              "scim_resource",
              resource.id,
              %{kind: kind}
            )

            view(resource)
        end
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_scim_resource}
    end
  rescue
    Ecto.ConstraintError -> {:error, :scim_identity_conflict}
  end

  def replace(kind, id, attrs, version, subject, effects) do
    mutate(kind, id, attrs, version, subject, effects, false)
  end

  def patch(kind, id, attrs, version, subject, effects) do
    mutate(kind, id, attrs, version, subject, effects, true)
  end

  def delete(kind, id, version, subject, effects) do
    with :ok <- CommsCore.ServiceAccounts.Authentication.preflight(subject, "scim:write"),
         {:ok, id} <- valid_id(id) do
      write_transaction(fn deadline ->
        tenant_id = value(subject, :tenant_id)
        locked_policy!(tenant_id)
        managed_user_ids = managed_user_ids(kind, id, tenant_id)
        authorize_write!(subject, deadline, managed_user_ids)
        %ScimResource{} = resource = locked_resource!(kind, id, tenant_id, version)
        ensure_managed_binding!(resource, managed_user_ids)

        revoked_session_ids =
          if resource.user_id do
            %User{} = user = locked_user!(resource.user_id, tenant_id)
            authorize_write!(subject, deadline, managed_user_ids)
            preserve_owner!(user)
            ids = revoke!(user, subject, effects)

            Repo.update!(
              Ecto.Changeset.change(%User{} = user,
                status: :suspended,
                lock_version: user.lock_version + 1
              )
            )

            # Retain the resource and immutable external key as a tombstone to stop recycled identity takeover.
            %ScimResource{} =
              resource =
              Repo.update!(
                Ecto.Changeset.change(%ScimResource{} = resource,
                  lock_version: resource.lock_version + 1
                )
              )

            Persistence.insert_audit!(
              subject,
              "identity.scim_deprovisioned",
              "scim_resource",
              resource.id,
              %{}
            )

            ids
          else
            authorize_write!(subject, deadline, managed_user_ids)
            Repo.delete!(resource)

            Persistence.insert_audit!(
              subject,
              "identity.scim_group_deleted",
              "scim_resource",
              resource.id,
              %{}
            )

            []
          end

        %{revoked_session_ids: revoked_session_ids}
      end)
    end
  end

  defp mutate(kind, id, attrs, version, subject, effects, patch?) do
    with :ok <- CommsCore.ServiceAccounts.Authentication.preflight(subject, "scim:write"),
         {:ok, id} <- valid_id(id) do
      write_transaction(fn deadline ->
        tenant_id = value(subject, :tenant_id)
        policy = locked_policy!(tenant_id)
        managed_user_ids = managed_user_ids(kind, id, tenant_id)
        authorize_write!(subject, deadline, managed_user_ids)
        %ScimResource{} = resource = locked_resource!(kind, id, tenant_id, version)
        ensure_managed_binding!(resource, managed_user_ids)
        attrs = if patch?, do: patch_attrs!(attrs, resource), else: attrs

        case reject_authority(attrs) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        if attrs["externalId"] && attrs["externalId"] != resource.external_id,
          do: Repo.rollback(:scim_identity_conflict)

        name = display_name(attrs)

        if name != nil and (not is_binary(name) or byte_size(name) not in 1..120),
          do: Repo.rollback(:invalid_scim_resource)

        changes = %{lock_version: resource.lock_version + 1}

        changes =
          if display_name(attrs),
            do: Map.put(changes, :display_name, display_name(attrs)),
            else: changes

        changes =
          if Map.has_key?(attrs, "members"),
            do: Map.put(changes, :members, members!(kind, attrs["members"], tenant_id)),
            else: changes

        revoked_session_ids =
          if resource.user_id do
            %User{} = user = locked_user!(resource.user_id, tenant_id)
            authorize_write!(subject, deadline, managed_user_ids)

            if attrs["userName"] && attrs["userName"] != user.email,
              do: Repo.rollback(:email_change_requires_verification)

            active = Map.get(attrs, "active", user.status == :active)
            if active not in [true, false], do: Repo.rollback(:invalid_scim_resource)

            ids =
              if not active do
                preserve_owner!(user)
                revoke!(user, subject, effects)
              else
                if user.status != :active do
                  case Directory.ensure_active_user_capacity(tenant_id, policy) do
                    :ok -> :ok
                    {:error, reason} -> Repo.rollback(reason)
                  end
                end

                []
              end

            user
            |> User.changeset(%{
              display_name: Map.get(changes, :display_name, user.display_name),
              status: if(active, do: :active, else: :suspended),
              lock_version: user.lock_version + 1
            })
            |> update!()

            ids
          else
            []
          end

        authorize_write!(subject, deadline, managed_user_ids)

        %ScimResource{} =
          resource = Repo.update!(Ecto.Changeset.change(%ScimResource{} = resource, changes))

        Persistence.insert_audit!(
          subject,
          "identity.scim_updated",
          "scim_resource",
          resource.id,
          %{version: resource.lock_version, kind: kind}
        )

        Map.put(view(resource), :revoked_session_ids, revoked_session_ids)
      end)
    end
  end

  defp patch_attrs!(%{"schemas" => schemas, "Operations" => operations}, resource)
       when is_list(schemas) and is_list(operations) and length(operations) in 1..25 do
    if "urn:ietf:params:scim:api:messages:2.0:PatchOp" not in schemas,
      do: Repo.rollback(:invalid_scim_patch)

    Enum.reduce(operations, %{}, fn op, acc ->
      if not is_map(op) or not is_binary(op["op"]), do: Repo.rollback(:invalid_scim_patch)
      operation = String.downcase(op["op"])
      path = op["path"]
      val = op["value"]

      cond do
        operation in ["add", "replace"] and is_nil(path) and is_map(val) ->
          Map.merge(acc, val)

        operation in ["add", "replace"] and
            path in ["active", "displayName", "userName", "externalId"] ->
          Map.put(acc, path, val)

        operation in ["add", "replace"] and path == "name.formatted" ->
          Map.put(acc, "displayName", val)

        operation == "replace" and path == "members" ->
          Map.put(acc, "members", val)

        operation == "add" and path == "members" and is_list(val) ->
          existing = Map.get(acc, "members", Enum.map(resource.members, &%{"value" => &1}))
          Map.put(acc, "members", Enum.uniq(existing ++ val))

        operation == "remove" and path == "members" ->
          Map.put(acc, "members", [])

        operation == "remove" and is_binary(path) ->
          case Regex.run(~r/^members\[value eq "([0-9a-f-]{36})"\]$/, path) do
            [_, id] ->
              Map.put(
                acc,
                "members",
                Enum.reject(
                  Map.get(acc, "members", Enum.map(resource.members, &%{"value" => &1})),
                  &(&1["value"] == id)
                )
              )

            _ ->
              Repo.rollback(:invalid_scim_patch)
          end

        true ->
          Repo.rollback(:invalid_scim_patch)
      end
    end)
  end

  defp patch_attrs!(_, _), do: Repo.rollback(:invalid_scim_patch)

  defp view(%ScimResource{kind: "User"} = resource) do
    user = Repo.get!(User, resource.user_id)

    %{
      schemas: [@user_schema],
      id: resource.id,
      externalId: resource.external_id,
      userName: user.email,
      displayName: user.display_name,
      active: user.status == :active,
      meta: %{
        resourceType: "User",
        created: resource.inserted_at,
        lastModified: resource.updated_at,
        version: etag(resource.lock_version)
      }
    }
  end

  defp view(%ScimResource{kind: "Group"} = resource) do
    %{
      schemas: [@group_schema],
      id: resource.id,
      externalId: resource.external_id,
      displayName: resource.display_name,
      members: Enum.map(resource.members, &%{value: &1}),
      meta: %{
        resourceType: "Group",
        created: resource.inserted_at,
        lastModified: resource.updated_at,
        version: etag(resource.lock_version)
      }
    }
  end

  defp members!("User", nil, _), do: []
  defp members!("User", _, _), do: Repo.rollback(:scim_group_authority_denied)
  defp members!("Group", nil, _), do: []

  defp members!("Group", members, tenant_id) when is_list(members) and length(members) <= 1000 do
    ids =
      Enum.map(members, fn
        %{"value" => id} ->
          case Ecto.UUID.cast(id) do
            {:ok, id} -> id
            _ -> Repo.rollback(:invalid_scim_member)
          end

        _ ->
          Repo.rollback(:invalid_scim_member)
      end)
      |> Enum.uniq()

    count =
      Repo.aggregate(
        from(r in ScimResource,
          where: r.tenant_id == ^tenant_id and r.kind == "User" and r.id in ^ids
        ),
        :count
      )

    if count != length(ids), do: Repo.rollback(:invalid_scim_member)
    ids
  end

  defp members!(_, _, _), do: Repo.rollback(:invalid_scim_member)

  defp provision_federation!(attrs, user) do
    if extension = attrs[@federation_schema] do
      config = Application.get_env(:comms_core, :oidc, %{})
      if not is_map(extension), do: Repo.rollback(:invalid_scim_resource)

      if config[:scim_subject_mapping] != true or extension["issuer"] != config[:issuer] or
           not is_binary(extension["subject"]) or byte_size(extension["subject"]) not in 1..512,
         do: Repo.rollback(:scim_federation_mapping_not_approved)

      Repo.insert!(%FederatedIdentity{
        tenant_id: user.tenant_id,
        user_id: user.id,
        issuer: extension["issuer"],
        subject: extension["subject"]
      })
    end
  end

  defp reject_authority(attrs) do
    if Enum.any?(
         ["roles", "role", "entitlements", "platform_role", "password", "groups", "account_type"],
         &Map.has_key?(attrs, &1)
       ), do: {:error, :scim_group_authority_denied}, else: :ok
  end

  defp preserve_owner!(
         %User{
           role: :owner,
           status: :active,
           account_type: :human,
           access_scope: :workspace
         } = user
       ) do
    if Repo.aggregate(
         from(u in User,
           where:
             u.tenant_id == ^user.tenant_id and u.status == :active and u.role == :owner and
               u.account_type == :human and u.access_scope == :workspace
         ),
         :count
       ) <= 1, do: Repo.rollback(:last_owner_required)
  end

  defp preserve_owner!(_), do: :ok

  defp revoke!(user, subject, effects) do
    ids =
      Repo.all(
        from(s in Session,
          where:
            s.tenant_id == ^user.tenant_id and s.user_id == ^user.id and is_nil(s.revoked_at),
          select: s.id
        )
      )

    Repo.update_all(
      from(s in Session,
        where: s.tenant_id == ^user.tenant_id and s.user_id == ^user.id and is_nil(s.revoked_at)
      ),
      set: [revoked_at: Persistence.now(), updated_at: Persistence.now()]
    )

    Repo.update_all(
      from(c in CommsCore.Accounts.AuthChallenge,
        where: c.tenant_id == ^user.tenant_id and c.user_id == ^user.id and is_nil(c.consumed_at)
      ),
      set: [consumed_at: Persistence.now()]
    )

    # The SCIM writer already retains canonical admission/Tenant/ordered User
    # authority. Native credentials and room epochs must be fenced in this
    # transaction, including when all K sessions were previously revoked.
    CommsCore.Accounts.MatrixSessions.revoke_sessions(user.tenant_id, ids)

    case CommsCore.Accounts.MatrixEligibilityPort.withdraw_user(
           %CommsCore.Accounts.MatrixEligibilityCommand{
             tenant_id: user.tenant_id,
             user_id: user.id,
             timestamp: Persistence.now()
           }
         ) do
      {:ok, %CommsCore.Accounts.MatrixEligibilityReceipt{}} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    effects.notify_identity_access_revoked.(
      NotificationCommand.user_access_revoked(user.tenant_id, user.id, "scim_suspended")
    )

    effects.revoke_identity_access.(
      CallLifecycleCommand.user_access_revoked(user.tenant_id, user.id, "scim_suspended")
    )

    Persistence.insert_audit!(subject, "identity.scim_sessions_revoked", "user", user.id, %{})
    ids
  end

  defp locked_policy!(tenant_id) do
    case AdmissionQuotas.locked_policy(tenant_id) do
      {:ok, policy} -> policy
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp locked_resource!(kind, id, tenant_id, version) do
    resource =
      Repo.one(
        from(r in ScimResource,
          where: r.id == ^id and r.tenant_id == ^tenant_id and r.kind == ^kind,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:not_found)

    if version != etag(resource.lock_version), do: Repo.rollback(:stale_version)
    resource
  end

  defp locked_user!(id, tenant_id),
    do:
      Repo.one!(
        from(u in User,
          where: u.id == ^id and u.tenant_id == ^tenant_id,
          lock: "FOR NO KEY UPDATE"
        )
      )

  defp managed_user_ids(kind, id, tenant_id) do
    case Repo.get_by(ScimResource, id: id, tenant_id: tenant_id, kind: kind) do
      %ScimResource{user_id: nil} -> []
      %ScimResource{user_id: user_id} -> [user_id]
      nil -> Repo.rollback(:not_found)
    end
  end

  defp ensure_managed_binding!(resource, managed_user_ids) do
    current_ids = if resource.user_id, do: [resource.user_id], else: []
    if current_ids != managed_user_ids, do: Repo.rollback(:scim_identity_conflict)
  end

  defp authorize_write!(subject, deadline, managed_user_ids \\ []) do
    set_write_budget!(deadline)

    case CommsCore.ServiceAccounts.Authentication.authorize(
           subject,
           "scim:write",
           deadline,
           managed_user_ids
         ) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp write_transaction(operation) do
    Repo.transaction(
      fn ->
        deadline = System.monotonic_time(:millisecond) + 30_000
        set_write_budget!(deadline)
        operation.(deadline)
      end,
      timeout: 35_000
    )
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] in [:query_canceled, :lock_not_available],
        do: {:error, :forbidden},
        else: reraise(error, __STACKTRACE__)
  end

  defp set_write_budget!(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond) - 1_000
    if remaining <= 0, do: Repo.rollback(:forbidden)

    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT set_config('statement_timeout', $1, true), set_config('lock_timeout', $1, true)",
      [Integer.to_string(remaining)]
    )
  end

  defp display_name(attrs) do
    case attrs["displayName"] do
      nil ->
        case attrs["name"] do
          %{"formatted" => name} -> name
          nil -> nil
          _ -> :invalid_scim_name
        end

      name ->
        name
    end
  end

  defp etag(version), do: "W/\"#{version}\""

  defp valid_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp bounded_integer(nil, default, _), do: {:ok, default}

  defp bounded_integer(val, _, maximum) when is_integer(val) and val in 1..maximum//1,
    do: {:ok, val}

  defp bounded_integer(val, default, maximum) when is_binary(val) do
    case Integer.parse(val) do
      {n, ""} -> bounded_integer(n, default, maximum)
      _ -> {:error, :invalid_scim_pagination}
    end
  end

  defp bounded_integer(_, _, _), do: {:error, :invalid_scim_pagination}
  defp filter(nil), do: {:ok, nil}

  defp filter(value) when is_binary(value) and byte_size(value) <= 1024 do
    case Regex.run(~r/^externalId eq "([^"\\]{1,512})"$/, value) do
      [_, id] -> {:ok, id}
      _ -> {:error, :invalid_scim_filter}
    end
  end

  defp filter(_), do: {:error, :invalid_scim_filter}

  defp insert!(changeset) do
    case Repo.insert(changeset) do
      {:ok, row} -> row
      {:error, _} -> Repo.rollback(:invalid_scim_resource)
    end
  end

  defp update!(changeset) do
    case Repo.update(changeset) do
      {:ok, row} -> row
      {:error, _} -> Repo.rollback(:invalid_scim_resource)
    end
  end

  defp value(map, key), do: Persistence.value(map, key)
end
