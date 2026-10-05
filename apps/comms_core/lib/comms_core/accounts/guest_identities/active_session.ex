defmodule CommsCore.Accounts.GuestIdentities.ActiveSession do
  @moduledoc false

  import Ecto.Query
  alias CommsCore.Accounts.{Device, GuestIdentityParentsLockQuery, Session, User}
  alias CommsCore.Accounts.GuestIdentities.{ParentAuthority, Persistence}
  alias CommsCore.Repo

  def lock_active(session_id, _timestamp, expected_user_id \\ nil) do
    with %Session{} = snapshot <- Repo.get(Session, session_id),
         true <- is_nil(expected_user_id) or snapshot.user_id == expected_user_id do
      lock_current(snapshot, true)
    else
      _ -> nil
    end
  end

  def lock_cleanup(session_id) do
    case Repo.get(Session, session_id) do
      %Session{} = snapshot -> lock_current(snapshot, false)
      _ -> nil
    end
  end

  def live?(%Session{user: %User{} = user, device: %Device{} = device} = session) do
    timestamp = Persistence.now()

    user.status == :active and user.account_type == :guest and
      user.access_scope == :conversation_only and
      match?(%DateTime{}, user.guest_expires_at) and
      DateTime.compare(user.guest_expires_at, timestamp) == :gt and
      is_nil(device.revoked_at) and is_nil(session.revoked_at) and
      DateTime.compare(session.expires_at, timestamp) == :gt and
      DateTime.compare(session.absolute_expires_at, timestamp) == :gt
  end

  defp lock_current(snapshot, live?) do
    deadline = ParentAuthority.deadline()

    with {:ok, _parents} <-
           ParentAuthority.lock(%GuestIdentityParentsLockQuery{
             tenant_id: snapshot.tenant_id,
             user_ids: [snapshot.user_id],
             deadline: deadline,
             require_active_tenant: live?
           }),
         :ok <- ParentAuthority.ensure_budget(),
         %User{account_type: :guest} = user <-
           Repo.get_by(User, id: snapshot.user_id, tenant_id: snapshot.tenant_id),
         %Device{} = device <-
           budgeted(fn ->
             Repo.one(
               from(device in Device,
                 where:
                   device.id == ^snapshot.device_id and device.user_id == ^snapshot.user_id and
                     device.tenant_id == ^snapshot.tenant_id,
                 lock: "FOR UPDATE"
               )
             )
           end),
         %Session{} = session <-
           budgeted(fn ->
             Repo.one(
               from(session in Session,
                 where:
                   session.id == ^snapshot.id and session.tenant_id == ^snapshot.tenant_id and
                     session.user_id == ^snapshot.user_id and
                     session.device_id == ^snapshot.device_id,
                 lock: "FOR UPDATE"
               )
             )
           end) do
      session = %{session | user: user, device: device}
      if not live? or live?(session), do: session, else: nil
    else
      _ -> nil
    end
  end

  defp budgeted(fun) do
    ParentAuthority.ensure_budget()
    result = fun.()
    ParentAuthority.ensure_budget()
    result
  end
end
