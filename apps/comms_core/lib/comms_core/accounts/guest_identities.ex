defmodule CommsCore.Accounts.GuestIdentities do
  @moduledoc false

  alias CommsCore.Accounts.GuestIdentities.{Conversion, SessionLifecycle}

  @spec provision(map(), map()) ::
          {:ok, CommsCore.Accounts.AuthenticationResult.t()}
          | {:error,
             :transaction_required
             | :tenant_unavailable
             | :invalid_guest_expiry
             | :active_user_quota_exceeded
             | :invalid_guest_identity}
  defdelegate provision(attrs, effects), to: SessionLifecycle

  @spec extend_ephemeral_authority(Ecto.UUID.t(), DateTime.t() | String.t()) ::
          {:ok,
           %{
             tenant_id: Ecto.UUID.t(),
             user_id: Ecto.UUID.t(),
             session_id: Ecto.UUID.t(),
             expires_at: DateTime.t()
           }}
          | {:error, :transaction_required | :invalid_ephemeral_guest_deadline | :session_expired}
  defdelegate extend_ephemeral_authority(session_id, deadline), to: SessionLifecycle

  @spec ensure_ephemeral_authority(Ecto.UUID.t(), DateTime.t() | String.t()) ::
          {:ok,
           %{
             tenant_id: Ecto.UUID.t(),
             user_id: Ecto.UUID.t(),
             session_id: Ecto.UUID.t(),
             expires_at: DateTime.t()
           }}
          | {:error, :transaction_required | :invalid_ephemeral_guest_deadline | :session_expired}
  defdelegate ensure_ephemeral_authority(session_id, deadline), to: SessionLifecycle

  @spec resume_ephemeral(map(), map()) ::
          {:ok, CommsCore.Accounts.AuthenticationResult.t()}
          | {:error,
             :transaction_required
             | :forbidden
             | :session_expired
             | :tenant_unavailable
             | :invalid_ephemeral_guest_deadline
             | :invalid_guest_identity}
  defdelegate resume_ephemeral(command, effects), to: SessionLifecycle

  @spec revoke_session(Ecto.UUID.t(), String.t(), map()) ::
          :ok | {:error, :not_found | :invalid_reason | term()}
  defdelegate revoke_session(session_id, reason, effects), to: SessionLifecycle

  @spec convert(map(), map(), String.t(), map()) ::
          {:ok, CommsCore.Accounts.AuthenticationResult.t()}
          | {:error,
             :forbidden
             | :guest_account_conversion_email_mismatch
             | :session_expired
             | :tenant_unavailable
             | :weak_password
             | :invalid_guest_account}
  defdelegate convert(attrs, guest_subject, preauthorized_email, effects),
    to: Conversion

  @spec convert_ephemeral(map(), map(), map()) ::
          {:ok, CommsCore.Accounts.AuthenticationResult.t()}
          | {:error,
             :forbidden
             | :transaction_required
             | :session_expired
             | :tenant_unavailable
             | :weak_password
             | :invalid_guest_account}
  defdelegate convert_ephemeral(attrs, guest_subject, effects), to: Conversion
end
