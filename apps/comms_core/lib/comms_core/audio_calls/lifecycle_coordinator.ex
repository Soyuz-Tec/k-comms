defmodule CommsCore.AudioCalls.LifecycleCoordinator do
  @moduledoc """
  Composes conversation-call and telephone-call revocation contributions.

  Both domains participate in the account or administration transaction. A
  failed contribution is returned to that owner so it rolls back the identity
  or policy change together with all call revocations and durable jobs.
  """
  @behaviour CommsCore.Accounts.CallLifecyclePort
  @behaviour CommsCore.Administration.CallLifecyclePort

  alias CommsCore.{AudioCalls, Repo, Telephony}
  alias CommsCore.Accounts.CallLifecycleCommand, as: IdentityCommand
  alias CommsCore.Accounts.CallLifecycleReceipt, as: IdentityReceipt
  alias CommsCore.Administration.CallLifecycleCommand, as: TenantCommand
  alias CommsCore.Administration.CallLifecycleReceipt, as: TenantReceipt

  @spec revoke_identity_access(IdentityCommand.t()) ::
          {:ok, IdentityReceipt.t()} | {:error, term()}
  @impl CommsCore.Accounts.CallLifecyclePort
  def revoke_identity_access(%IdentityCommand{} = command) do
    if Repo.in_transaction?() do
      with {:ok, %IdentityReceipt{revoked_participant_count: audio_count}} <-
             AudioCalls.revoke_identity_access(command),
           {:ok, %IdentityReceipt{revoked_participant_count: phone_count}} <-
             Telephony.revoke_identity_access(command) do
        {:ok, %IdentityReceipt{revoked_participant_count: audio_count + phone_count}}
      else
        {:error, _reason} = error -> error
        _unexpected -> {:error, :call_lifecycle_unavailable}
      end
    else
      {:error, :transaction_required}
    end
  end

  @spec revoke_tenant_media(TenantCommand.t()) ::
          {:ok, TenantReceipt.t()} | {:error, term()}
  @impl CommsCore.Administration.CallLifecyclePort
  def revoke_tenant_media(%TenantCommand{} = command) do
    if Repo.in_transaction?() do
      with {:ok, %TenantReceipt{revoked_participant_count: audio_count}} <-
             AudioCalls.revoke_tenant_media(command),
           {:ok, %TenantReceipt{revoked_participant_count: phone_count}} <-
             Telephony.revoke_tenant_media(command) do
        {:ok, %TenantReceipt{revoked_participant_count: audio_count + phone_count}}
      else
        {:error, _reason} = error -> error
        _unexpected -> {:error, :call_lifecycle_unavailable}
      end
    else
      {:error, :transaction_required}
    end
  end
end
