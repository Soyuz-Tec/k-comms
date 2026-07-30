defmodule CommsCore.Accounts.UserLifecycle do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Accounts.{
    AccessControl,
    CallLifecycleCommand,
    Device,
    Directory,
    NotificationCommand,
    PlatformGrants,
    Session,
    User
  }

  alias CommsCore.Administration.AdmissionPolicy
  alias CommsCore.{AdmissionQuotas, Audit, Repo}
  alias CommsCore.Security.Password

  def list_tenant_views(subject) do
    case AccessControl.access_grant(subject) do
      {:ok, %{access_scope: :workspace}} ->
        subject |> list_tenant_users() |> Enum.map(&CommsCore.Accounts.Projector.user/1)

      _ ->
        []
    end
  end

  def list_admin_views(subject) do
    with {:ok, users} <- list_admin(subject) do
      {:ok, Enum.map(users, &CommsCore.Accounts.Projector.user(&1, platform_access: true))}
    end
  end

  def update_profile_view(attrs, subject),
    do:
      update_profile(attrs, subject)
      |> project_result(&CommsCore.Accounts.Projector.user(&1, platform_access: true))

  def change_with_effects_view(id, attrs, subject, effects) do
    with {:ok, result} <- change_with_effects(id, attrs, subject, effects) do
      {:ok,
       %{result | user: CommsCore.Accounts.Projector.user(result.user, platform_access: true)}}
    end
  end

  def create(attrs, subject) when is_map(attrs) and is_map(subject) do
    tenant_id = value(subject, :tenant_id)
    password = value(attrs, :password)
    email = value(attrs, :email) |> to_string() |> String.trim() |> String.downcase()
    user_id = Ecto.UUID.generate()

    with :ok <- PlatformGrants.reject_user_attributes(attrs),
         :ok <- reject_service_account_attribute(attrs),
         {:ok, requested_role} <- requested_role(attrs),
         :ok <- AccessControl.authorize_manage_user_lifecycle(subject),
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

      Ecto.Multi.new()
      |> Ecto.Multi.run(:admission_quota, fn _repo, _changes ->
        with {:ok, policy} <- AdmissionQuotas.locked_policy(tenant_id),
             :ok <- Directory.ensure_active_user_capacity(tenant_id, policy) do
          {:ok, :admitted}
        end
      end)
      |> Ecto.Multi.insert(:user, user_changeset)
      |> Audit.append(%{
        tenant_id: tenant_id,
        actor_user_id: value(subject, :user_id),
        action: "user.create",
        resource_type: "user",
        resource_id: user_id,
        metadata: %{email: email, role: requested_role},
        request_id: value(subject, :request_id)
      })
      |> Repo.transaction()
      |> case do
        {:ok, %{user: user}} -> {:ok, user}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  def list_admin(subject) do
    with :ok <- AccessControl.authorize_administer_users(subject) do
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
        case validate_unchanged_profile_email(attrs, user.email) do
          :ok -> Map.take(attrs, [:display_name, "display_name"])
          {:error, reason} -> Repo.rollback(reason)
        end

      updated = user |> User.changeset(changes) |> update_or_rollback()

      insert_audit!(subject, "user.profile_update", "user", user.id, %{
        before: %{display_name: user.display_name},
        after: %{display_name: updated.display_name}
      })

      updated
    end)
    |> transaction_result()
  end

  def change(user_id, attrs, subject, effects)
      when is_map(attrs) and is_map(subject) and is_map(effects) do
    case change_with_effects(user_id, attrs, subject, effects) do
      {:ok, result} -> {:ok, result.user}
      {:error, _} = error -> error
    end
  end

  def change_with_effects(user_id, attrs, subject, effects)
      when is_map(attrs) and is_map(subject) and is_map(effects) do
    with {:ok, command} <- validate_change(attrs, subject) do
      Repo.transaction(fn ->
        apply_change!(
          user_id,
          command,
          subject,
          :governance_policy_required,
          effects
        )
      end)
      |> transaction_result()
    end
  end

  def preflight(user_id, attrs, subject)
      when is_map(attrs) and is_map(subject) do
    cond do
      not valid_uuid?(user_id) ->
        {:error, :not_found}

      not valid_uuid?(value(subject, :tenant_id)) ->
        {:error, :forbidden}

      true ->
        with {:ok, _command} <- validate_change(attrs, subject), do: :ok
    end
  end

  def preflight(_user_id, _attrs, _subject), do: {:error, :not_found}

  @spec apply_change(Ecto.UUID.t(), map(), map(), [Ecto.UUID.t()], map()) ::
          {:ok, %{user: CommsCore.Accounts.UserView.t(), revoked_session_ids: [Ecto.UUID.t()]}}
          | {:error, term()}
  def apply_change(user_id, attrs, subject, excluded_owner_ids, effects)
      when is_map(attrs) and is_map(subject) and is_map(effects) do
    cond do
      not Repo.in_transaction?() ->
        {:error, :transaction_required}

      not valid_uuid?(user_id) ->
        {:error, :not_found}

      not valid_owner_exclusions?(excluded_owner_ids) ->
        {:error, :invalid_owner_exclusions}

      true ->
        with {:ok, command} <- validate_change(attrs, subject) do
          result =
            apply_change!(
              user_id,
              command,
              subject,
              Enum.uniq(excluded_owner_ids),
              effects
            )

          {:ok,
           %{result | user: CommsCore.Accounts.Projector.user(result.user, platform_access: true)}}
        end
    end
  end

  def apply_change(_user_id, _attrs, _subject, _excluded_owner_ids, _effects),
    do: {:error, :invalid_owner_exclusions}

  def get_for_subject(subject) do
    Repo.get_by(User,
      id: value(subject, :user_id),
      tenant_id: value(subject, :tenant_id),
      status: :active
    )
  end

  defp list_tenant_users(subject) do
    tenant_id = value(subject, :tenant_id)

    User
    |> where([u], u.tenant_id == ^tenant_id and u.status != :deleted)
    |> order_by([u], asc: fragment("lower(?)", u.display_name))
    |> preload(:platform_role_grant)
    |> Repo.all()
  end

  defp validate_change(attrs, subject) do
    tenant_id = value(subject, :tenant_id)

    if valid_uuid?(tenant_id) do
      with :ok <- PlatformGrants.reject_user_attributes(attrs),
           :ok <- reject_service_account_attribute(attrs),
           :ok <- AccessControl.authorize_manage_user_lifecycle(subject),
           {:ok, reason} <- required_reason(attrs),
           {:ok, expected_version} <- expected_version(attrs),
           {:ok, role} <- optional_role(attrs),
           {:ok, status} <- optional_status(attrs) do
        {:ok,
         %{
           tenant_id: tenant_id,
           reason: reason,
           expected_version: expected_version,
           role: role,
           status: status,
           display_name: value(attrs, :display_name)
         }}
      end
    else
      {:error, :forbidden}
    end
  end

  defp apply_change!(user_id, command, subject, excluded_owner_ids, effects) do
    tenant_id = command.tenant_id

    policy = AdmissionQuotas.locked_policy(tenant_id) |> admission_policy_or_rollback()
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

    if target.lock_version != command.expected_version, do: Repo.rollback(:stale_version)

    actor =
      Repo.get_by!(User,
        id: value(subject, :user_id),
        tenant_id: tenant_id,
        status: :active,
        account_type: :human,
        access_scope: :workspace
      )

    authorize_user_change!(actor, target, command.role, command.status)
    ensure_last_owner!(target, command.role, command.status, excluded_owner_ids)

    if target.status != :active and command.status == :active do
      quota_ok!(Directory.ensure_active_user_capacity(tenant_id, policy))
    end

    changes =
      %{}
      |> maybe_put(:role, command.role)
      |> maybe_put(:status, command.status)
      |> maybe_put(:display_name, command.display_name)

    updated =
      target
      |> User.changeset(changes)
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> update_or_validation_error(effects)

    revoked_session_ids =
      if updated.status != :active, do: revoke_user_access!(updated, effects), else: []

    insert_audit!(subject, "user.lifecycle_update", "user", target.id, %{
      reason: command.reason,
      before: %{role: target.role, status: target.status, display_name: target.display_name},
      after: %{role: updated.role, status: updated.status, display_name: updated.display_name}
    })

    %{user: updated, revoked_session_ids: revoked_session_ids}
  end

  defp revoke_user_access!(user, effects) do
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

    NotificationCommand.user_access_revoked(
      user.tenant_id,
      user.id,
      "user_lifecycle_revoked"
    )
    |> effects.notify_identity_access_revoked.()

    CallLifecycleCommand.user_access_revoked(
      user.tenant_id,
      user.id,
      "user_lifecycle_revoked"
    )
    |> effects.revoke_identity_access.()

    session_ids
  end

  defp valid_owner_exclusions?(values) when is_list(values),
    do: Enum.all?(values, &valid_uuid?/1)

  defp valid_owner_exclusions?(_values), do: false

  defp valid_uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

  defp lock_tenant_users!(tenant_id) do
    Repo.all(
      from(u in User,
        where: u.tenant_id == ^tenant_id,
        order_by: [asc: u.id],
        select: u.id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp ensure_last_owner!(
         %User{role: :owner, status: :active},
         role,
         status,
         :governance_policy_required
       )
       when role not in [nil, :owner] or status not in [nil, :active],
       do: Repo.rollback(:governance_policy_required)

  defp ensure_last_owner!(
         %User{role: :owner, status: :active} = target,
         role,
         status,
         excluded_owner_ids
       )
       when (role not in [nil, :owner] or status not in [nil, :active]) and
              is_list(excluded_owner_ids) do
    remaining =
      User
      |> where(
        [u],
        u.tenant_id == ^target.tenant_id and u.id != ^target.id and u.role == :owner and
          u.status == :active and u.id not in ^excluded_owner_ids
      )
      |> Repo.aggregate(:count)

    if remaining == 0, do: Repo.rollback(:last_owner_required)
  end

  defp ensure_last_owner!(_, _, _, _), do: :ok

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
           status: :active,
           access_scope: :workspace
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

  defp validate_unchanged_profile_email(attrs, current_email) do
    supplied_emails =
      [:email, "email"]
      |> Enum.filter(&Map.has_key?(attrs, &1))
      |> Enum.map(&Map.fetch!(attrs, &1))

    unchanged? =
      Enum.all?(supplied_emails, fn
        email when is_binary(email) -> normalize_email(email) == normalize_email(current_email)
        _ -> false
      end)

    if unchanged?, do: :ok, else: {:error, :email_change_requires_verification}
  end

  defp normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  defp normalize_email(_email), do: ""

  defp validate_password(password) do
    if Password.valid_password?(password), do: :ok, else: {:error, :weak_password}
  end

  defp audit_command(subject, action, resource_type, resource_id, metadata) do
    %{
      tenant_id: value(subject, :tenant_id),
      actor_user_id: value(subject, :user_id),
      action: action,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: metadata,
      request_id: value(subject, :request_id)
    }
  end

  defp insert_audit!(subject, action, resource_type, resource_id, metadata) do
    subject
    |> audit_command(action, resource_type, resource_id, metadata)
    |> Audit.record()
    |> audit_or_rollback()
  end

  defp audit_or_rollback({:ok, event}), do: event
  defp audit_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_or_validation_error(changeset, effects) do
    case Repo.update(changeset) do
      {:ok, value} ->
        value

      {:error, invalid_changeset} ->
        Repo.rollback(effects.validation_error_from_changeset.(invalid_changeset))
    end
  end

  defp quota_ok!(:ok), do: :ok
  defp quota_ok!({:error, reason}), do: Repo.rollback(reason)

  defp admission_policy_or_rollback({:ok, %AdmissionPolicy{} = policy}), do: policy
  defp admission_policy_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp project_result({:ok, result}, projector), do: {:ok, projector.(result)}
  defp project_result({:error, _reason} = error, _projector), do: error

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
