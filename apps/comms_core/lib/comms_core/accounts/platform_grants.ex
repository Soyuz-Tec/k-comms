defmodule CommsCore.Accounts.PlatformGrants do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Accounts.{PlatformRoleGrant, User}
  alias CommsCore.{Audit, Repo}

  @platform_roles PlatformRoleGrant.roles()
  @platform_role_min_ttl_seconds 300
  @platform_role_max_ttl_seconds 28_800

  @doc """
  Grants or revokes a time-bounded platform role from an authenticated
  release/console workflow.

  This function is intentionally separate from tenant administration changesets and
  HTTP controllers. It fails closed unless a strong management secret is configured,
  the caller supplies that secret using `:grant_token`, and explicit `:actor` and
  `:reason` evidence is provided. Grants also require `:ttl_seconds` between five
  minutes and eight hours. The grant update and audit event commit atomically.
  Passing `nil`, `"none"`, or `"revoke"` revokes the current platform role and
  ignores `:ttl_seconds`.
  """
  def set_from_console(user_id, role, attrs)
      when is_binary(user_id) and is_map(attrs) do
    with {:ok, configured_secret} <- management_secret(),
         :ok <-
           verify_management_secret(configured_secret, value(attrs, :grant_token)),
         {:ok, platform_role} <- normalize_role(role),
         {:ok, ttl_seconds} <- role_ttl(platform_role, value(attrs, :ttl_seconds)),
         {:ok, actor} <- required_audit_text(attrs, :actor, 3, 120),
         {:ok, reason} <- required_audit_text(attrs, :reason, 8, 500) do
      Repo.transaction(fn ->
        user =
          Repo.one(
            from(u in User,
              where: u.id == ^user_id,
              lock: "FOR UPDATE"
            )
          ) ||
            Repo.rollback(:not_found)

        authorize_target!(user, platform_role)

        previous_grant =
          Repo.one(
            from(g in PlatformRoleGrant,
              where: g.user_id == ^user.id and g.tenant_id == ^user.tenant_id,
              lock: "FOR UPDATE"
            )
          )

        expires_at =
          if platform_role,
            do: DateTime.add(now(), ttl_seconds, :second),
            else: nil

        current_grant =
          replace_grant!(user, previous_grant, platform_role, expires_at)

        updated =
          user
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()
          |> with_access(platform_role, expires_at)

        action = if is_nil(platform_role), do: "platform_role.revoke", else: "platform_role.grant"

        Audit.record(%{
          tenant_id: user.tenant_id,
          actor_user_id: nil,
          action: action,
          resource_type: "user",
          resource_id: user.id,
          metadata: %{
            actor: actor,
            reason: reason,
            source: "release_console",
            before_grant_id: previous_grant && previous_grant.id,
            before: previous_grant && previous_grant.role,
            before_expires_at: previous_grant && previous_grant.expires_at,
            after_grant_id: current_grant && current_grant.id,
            after: platform_role,
            after_expires_at: expires_at,
            ttl_seconds: ttl_seconds
          }
        })
        |> audit_or_rollback()

        updated
      end)
      |> transaction_result()
    end
  end

  def set_from_console(_user_id, _role, _attrs),
    do: {:error, :invalid_platform_role_request}

  @doc false
  def reject_user_attributes(attrs) when is_map(attrs) do
    if Map.has_key?(attrs, :platform_role) or Map.has_key?(attrs, "platform_role") or
         Map.has_key?(attrs, :platform_role_expires_at) or
         Map.has_key?(attrs, "platform_role_expires_at"),
       do: {:error, :platform_role_console_only},
       else: :ok
  end

  @doc false
  def maybe_apply_bootstrap(%User{} = user) do
    if Application.get_env(:comms_core, :allow_bootstrap_platform_role, false) do
      with {:ok, role} when not is_nil(role) <-
             normalize_role(Application.get_env(:comms_core, :bootstrap_platform_role)),
           {:ok, ttl_seconds} <-
             role_ttl(
               role,
               Application.get_env(
                 :comms_core,
                 :bootstrap_platform_role_ttl_seconds,
                 @platform_role_max_ttl_seconds
               )
             ) do
        case grant(user.id, user.tenant_id) do
          %PlatformRoleGrant{role: ^role} = current_grant ->
            if DateTime.compare(current_grant.expires_at, now()) == :gt,
              do: with_access(user, current_grant.role, current_grant.expires_at),
              else: renew_bootstrap!(user, current_grant, role, ttl_seconds)

          previous_grant ->
            renew_bootstrap!(user, previous_grant, role, ttl_seconds)
        end
      else
        _ -> Repo.rollback(:invalid_bootstrap_platform_role)
      end
    else
      user
    end
  end

  defp renew_bootstrap!(user, previous_grant, role, ttl_seconds) do
    expires_at = DateTime.add(now(), ttl_seconds, :second)
    current_grant = replace_grant!(user, previous_grant, role, expires_at)

    Audit.record(%{
      tenant_id: user.tenant_id,
      actor_user_id: nil,
      action: "platform_role.bootstrap_grant",
      resource_type: "user",
      resource_id: user.id,
      metadata: %{
        actor: "release_bootstrap",
        reason: "explicit local-proof bootstrap configuration",
        source: "local_proof",
        before_grant_id: previous_grant && previous_grant.id,
        before: previous_grant && previous_grant.role,
        before_expires_at: previous_grant && previous_grant.expires_at,
        after_grant_id: current_grant.id,
        after: role,
        after_expires_at: expires_at,
        ttl_seconds: ttl_seconds
      }
    })
    |> audit_or_rollback()

    with_access(user, role, expires_at)
  end

  defp normalize_role(role) when role in [nil, "", "none", "revoke"], do: {:ok, nil}

  defp normalize_role(role) do
    case normalize_enum(role, @platform_roles) do
      nil -> {:error, :invalid_platform_role}
      normalized -> {:ok, normalized}
    end
  end

  defp role_ttl(nil, _value), do: {:ok, nil}

  defp role_ttl(_role, value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {ttl, ""} -> role_ttl(:grant, ttl)
      _ -> {:error, :invalid_platform_role_ttl}
    end
  end

  defp role_ttl(_role, value)
       when is_integer(value) and
              value >= @platform_role_min_ttl_seconds and
              value <= @platform_role_max_ttl_seconds,
       do: {:ok, value}

  defp role_ttl(_role, _value), do: {:error, :invalid_platform_role_ttl}

  defp grant(user_id, tenant_id) do
    Repo.get_by(PlatformRoleGrant, user_id: user_id, tenant_id: tenant_id)
  end

  defp authorize_target!(_user, nil), do: :ok

  defp authorize_target!(
         %User{status: :active, account_type: :human, access_scope: :workspace},
         _role
       ),
       do: :ok

  defp authorize_target!(_user, _role), do: Repo.rollback(:not_found)

  defp replace_grant!(_user, nil, nil, nil), do: nil

  defp replace_grant!(_user, %PlatformRoleGrant{} = grant, nil, nil) do
    case Repo.delete(grant) do
      {:ok, _grant} -> nil
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp replace_grant!(user, previous_grant, role, expires_at) do
    if previous_grant do
      case Repo.delete(previous_grant) do
        {:ok, _grant} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end

    grant_id = Ecto.UUID.generate()

    %PlatformRoleGrant{id: grant_id}
    |> PlatformRoleGrant.changeset(%{
      id: grant_id,
      tenant_id: user.tenant_id,
      user_id: user.id,
      role: role,
      expires_at: expires_at
    })
    |> insert_or_rollback()
  end

  defp with_access(%User{} = user, role, expires_at) do
    %{user | platform_role: role, platform_role_expires_at: expires_at}
  end

  defp management_secret do
    case Application.get_env(:comms_core, :platform_role_management_secret) do
      secret when is_binary(secret) and byte_size(secret) >= 32 -> {:ok, secret}
      _ -> {:error, :platform_role_management_unavailable}
    end
  end

  defp verify_management_secret(configured_secret, provided_secret) do
    provided_secret = if is_binary(provided_secret), do: provided_secret, else: ""

    configured_digest = :crypto.hash(:sha256, configured_secret)
    provided_digest = :crypto.hash(:sha256, provided_secret)

    if :crypto.hash_equals(configured_digest, provided_digest),
      do: :ok,
      else: {:error, :invalid_platform_role_management_secret}
  end

  defp required_audit_text(attrs, key, min_length, max_length) do
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

  defp normalize_enum(value, allowed) when is_atom(value), do: if(value in allowed, do: value)

  defp normalize_enum(value, allowed) when is_binary(value) do
    Enum.find(allowed, &(Atom.to_string(&1) == value))
  end

  defp normalize_enum(_, _), do: nil

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

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
