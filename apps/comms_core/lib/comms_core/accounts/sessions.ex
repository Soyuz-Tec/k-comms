defmodule CommsCore.Accounts.Sessions do
  @moduledoc """
  Owns the stable IdentityAccess session API.

  Authentication, refresh rotation, socket tickets, session management, and
  persistence are delegated to cohesive internal modules. `CommsCore.Accounts`
  remains the public context facade.
  """

  alias CommsCore.Accounts.Sessions.{
    Authentication,
    Management,
    Persistence,
    RefreshTokens,
    SocketTickets
  }

  defdelegate authenticate(tenant_slug, email, password, device_attrs \\ %{}),
    to: Authentication

  defdelegate refresh(token), to: RefreshTokens

  @doc false
  defdelegate refresh_guest(token), to: RefreshTokens

  defdelegate get_active(id), to: Persistence

  @doc false
  defdelegate active_with_tenant(id), to: Persistence

  @doc false
  defdelegate active_guest_with_tenant(id), to: Persistence

  defdelegate issue_socket_ticket(subject), to: SocketTickets, as: :issue

  defdelegate issue_guest_socket_ticket(subject), to: SocketTickets, as: :issue_guest

  defdelegate consume_socket_ticket(ticket), to: SocketTickets, as: :consume

  defdelegate revoke(session_id, user_id, effects), to: Management

  defdelegate change_password(attrs, subject, effects), to: Management

  defdelegate change_password_with_effects(attrs, subject, effects), to: Management

  defdelegate step_up(attrs, subject), to: Management

  defdelegate list_devices(subject), to: Management

  defdelegate list_sessions(subject), to: Management

  defdelegate revoke_device(device_id, subject, effects), to: Management

  defdelegate revoke_own(session_id, subject, effects), to: Management

  defdelegate list_user_sessions(user_id, subject), to: Management

  defdelegate admin_revoke(user_id, session_id, attrs, subject, effects), to: Management

  defdelegate subject(session, request_id \\ nil), to: Persistence

  @doc false
  defdelegate lock_active_guest(subject), to: Persistence

  @doc false
  defdelegate create_or_rollback(user, device), to: RefreshTokens

  @doc false
  defdelegate create_guest_or_rollback(user, device, guest_expires_at, created_at),
    to: RefreshTokens

  @doc false
  defdelegate new_deadlines(created_at), to: RefreshTokens

  @doc false
  defdelegate new_refresh_token(session_id), to: RefreshTokens
end
