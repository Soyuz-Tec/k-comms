defmodule CommsCore.Accounts.Sessions.Management do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Accounts.{AccessControl, Device, Session, User}
  alias CommsCore.Accounts.Sessions.Persistence
  alias CommsCore.Repo
  alias CommsCore.Security.Password

  def revoke(session_id, user_id, effects) do
    Repo.transaction(fn ->
      session =
        Repo.one(
          from(s in Session,
            where: s.id == ^session_id and s.user_id == ^user_id,
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:not_found)

      session
      |> Session.changeset(%{revoked_at: Persistence.now()})
      |> update_or_rollback()

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
    current_password = Persistence.value(attrs, :current_password)
    new_password = Persistence.value(attrs, :new_password)

    with :ok <- validate_password(new_password) do
      Repo.transaction(fn ->
        user =
          Repo.one(
            from(u in User,
              where:
                u.id == ^Persistence.value(subject, :user_id) and
                  u.tenant_id == ^Persistence.value(subject, :tenant_id) and
                  u.status == :active and u.account_type == :human,
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
        Persistence.insert_audit!(subject, "user.password_change", "user", user.id, %{})
        %{user: updated, revoked_session_ids: revoked_session_ids}
      end)
      |> Persistence.transaction_result()
    end
  end

  def step_up(attrs, subject) when is_map(attrs) and is_map(subject) do
    password = Persistence.value(attrs, :current_password)

    Repo.transaction(fn ->
      user =
        Repo.one(
          from(u in User,
            where:
              u.id == ^Persistence.value(subject, :user_id) and
                u.tenant_id == ^Persistence.value(subject, :tenant_id) and
                u.status == :active and u.account_type == :human,
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:not_found)

      unless Password.verify(password, user.password_hash),
        do: Repo.rollback(:invalid_current_password)

      session =
        Repo.one(
          from(s in Session,
            where:
              s.id == ^Persistence.value(subject, :session_id) and s.user_id == ^user.id and
                s.tenant_id == ^user.tenant_id and is_nil(s.revoked_at) and
                s.expires_at > ^Persistence.now() and
                s.absolute_expires_at > ^Persistence.now(),
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:session_expired)

      stepped_up =
        session
        |> Session.changeset(%{step_up_at: Persistence.now()})
        |> update_or_rollback()

      Persistence.insert_audit!(subject, "session.step_up", "session", session.id, %{})
      stepped_up
    end)
    |> Persistence.transaction_result()
  end

  def list_devices(subject) do
    Device
    |> where(
      [d],
      d.tenant_id == ^Persistence.value(subject, :tenant_id) and
        d.user_id == ^Persistence.value(subject, :user_id)
    )
    |> order_by([d], desc: d.last_seen_at, desc: d.inserted_at)
    |> Repo.all()
  end

  def list_sessions(subject) do
    Session
    |> where(
      [s],
      s.tenant_id == ^Persistence.value(subject, :tenant_id) and
        s.user_id == ^Persistence.value(subject, :user_id)
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
              d.id == ^device_id and
                d.tenant_id == ^Persistence.value(subject, :tenant_id) and
                d.user_id == ^Persistence.value(subject, :user_id),
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:not_found)

      timestamp = Persistence.now()

      device
      |> Device.changeset(%{revoked_at: timestamp})
      |> update_or_rollback()

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

      Persistence.insert_audit!(subject, "device.revoke", "device", device.id, %{})
      %{device: device, revoked_session_ids: session_ids}
    end)
    |> Persistence.transaction_result()
  end

  def revoke_own(session_id, subject, effects) do
    revoke_scoped_session(
      session_id,
      Persistence.value(subject, :user_id),
      subject,
      effects
    )
  end

  def list_user_sessions(user_id, subject) do
    with :ok <- AccessControl.authorize_manage_sessions(subject),
         %User{} = actor <- active_actor(subject),
         %User{} = target <-
           Repo.get_by(User,
             id: user_id,
             tenant_id: Persistence.value(subject, :tenant_id),
             account_type: :human
           ),
         :ok <- authorize_session_target(actor, target) do
      {:ok,
       Session
       |> where(
         [s],
         s.tenant_id == ^Persistence.value(subject, :tenant_id) and s.user_id == ^user_id
       )
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
                u.id == ^user_id and
                  u.tenant_id == ^Persistence.value(subject, :tenant_id) and
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
          |> Session.changeset(%{revoked_at: Persistence.now()})
          |> update_or_rollback()

        effects.revoke_sessions.(
          target.tenant_id,
          [revoked.id],
          "session_admin_revoked"
        )

        Persistence.insert_audit!(
          subject,
          "session.admin_revoke",
          "session",
          session.id,
          %{user_id: target.id, reason: reason}
        )

        revoked
      end)
      |> Persistence.transaction_result()
    end
  end

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
                s.tenant_id == ^Persistence.value(subject, :tenant_id),
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:not_found)

      timestamp = Persistence.now()

      session
      |> Session.changeset(%{revoked_at: timestamp})
      |> update_or_rollback()

      effects.revoke_sessions.(session.tenant_id, [session.id], "session_revoked")

      Persistence.insert_audit!(
        subject,
        action,
        "session",
        session.id,
        %{user_id: user_id}
      )

      session
    end)
    |> Persistence.transaction_result()
  end

  defp revoke_other_sessions!(subject, effects) do
    query =
      Session
      |> where(
        [s],
        s.tenant_id == ^Persistence.value(subject, :tenant_id) and
          s.user_id == ^Persistence.value(subject, :user_id) and
          s.id != ^Persistence.value(subject, :session_id) and is_nil(s.revoked_at)
      )

    ids = query |> select([s], s.id) |> Repo.all()
    Repo.update_all(query, set: [revoked_at: Persistence.now(), updated_at: Persistence.now()])

    effects.revoke_sessions.(
      Persistence.value(subject, :tenant_id),
      ids,
      "password_changed"
    )

    ids
  end

  defp validate_password(password) do
    if Password.valid_password?(password), do: :ok, else: {:error, :weak_password}
  end

  defp active_actor(subject) do
    Repo.get_by(User,
      id: Persistence.value(subject, :user_id),
      tenant_id: Persistence.value(subject, :tenant_id),
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
    case Persistence.value(attrs, :reason) do
      reason when is_binary(reason) ->
        normalized = String.trim(reason)

        if String.length(normalized) in 3..1_000,
          do: {:ok, normalized},
          else: {:error, :reason_required}

      _ ->
        {:error, :reason_required}
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
