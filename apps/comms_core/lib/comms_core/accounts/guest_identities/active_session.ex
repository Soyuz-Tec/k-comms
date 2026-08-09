defmodule CommsCore.Accounts.GuestIdentities.ActiveSession do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Accounts.{Device, Session, User}
  alias CommsCore.Repo

  def lock_active(session_id, timestamp, expected_user_id \\ nil) do
    Session
    |> join(:inner, [session], user in User,
      on: user.id == session.user_id and user.tenant_id == session.tenant_id
    )
    |> join(:inner, [session, _user], device in Device,
      on:
        device.id == session.device_id and device.user_id == session.user_id and
          device.tenant_id == session.tenant_id
    )
    |> where(
      [session, user, device],
      session.id == ^session_id and is_nil(session.revoked_at) and
        session.expires_at > ^timestamp and session.absolute_expires_at > ^timestamp and
        user.status == :active and user.account_type == :guest and
        user.access_scope == :conversation_only and not is_nil(user.guest_expires_at) and
        user.guest_expires_at > ^timestamp and is_nil(device.revoked_at)
    )
    |> maybe_filter_user(expected_user_id)
    |> preload([_session, user, device], user: user, device: device)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp maybe_filter_user(query, nil), do: query

  defp maybe_filter_user(query, expected_user_id) do
    where(query, [session, _user, _device], session.user_id == ^expected_user_id)
  end
end
