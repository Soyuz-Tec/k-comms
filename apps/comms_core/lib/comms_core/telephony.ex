defmodule CommsCore.Telephony do
  @moduledoc """
  Tenant-contained individual telephone calls, provisioning and durable call records.

  Provider events are accepted only through the configured verified integration;
  provider commands and cleanup are durable worker contributions.
  """
  alias CommsCore.Telephony.{
    CallView,
    CredentialRequest,
    Lifecycle,
    ProviderCommand,
    ProviderWebhookPort,
    VerifiedProviderEvent
  }

  @type response :: {:ok, map() | CallView.t()} | {:error, atom() | CommsCore.ValidationError.t()}
  @spec config(map()) :: response()
  defdelegate config(subject), to: Lifecycle
  @spec admin_config(map()) :: response()
  defdelegate admin_config(subject), to: Lifecycle
  @spec provision(map(), map()) :: response()
  defdelegate provision(attrs, subject), to: Lifecycle
  @spec list_calls(map()) :: response()
  def list_calls(subject), do: Lifecycle.list_calls(subject, %{})
  @spec list_calls(map(), map()) :: response()
  defdelegate list_calls(subject, params), to: Lifecycle
  @spec get_call(String.t(), map()) :: response()
  defdelegate get_call(id, subject), to: Lifecycle

  @spec start_outbound(map(), map()) ::
          {:ok, CallView.t(), :created | :replayed}
          | {:error, atom() | CommsCore.ValidationError.t()}
  defdelegate start_outbound(attrs, subject), to: Lifecycle

  @spec answer(String.t(), map(), (CredentialRequest.t() -> {:ok, map()} | {:error, atom()})) ::
          {:ok, CallView.t(), map()} | {:error, atom()}
  defdelegate answer(id, subject, issuer), to: Lifecycle

  @spec join(String.t(), map(), (CredentialRequest.t() -> {:ok, map()} | {:error, atom()})) ::
          {:ok, CallView.t(), map()} | {:error, atom()}
  defdelegate join(id, subject, issuer), to: Lifecycle
  @spec reject(String.t(), map()) :: response()
  defdelegate reject(id, subject), to: Lifecycle
  @spec end_call(String.t(), map()) :: response()
  defdelegate end_call(id, subject), to: Lifecycle

  @spec callback(map(), module()) ::
          {:ok, CallView.t() | nil, :applied | :duplicate | :ignored} | {:error, atom()}
  defdelegate callback(event, caller), to: Lifecycle

  @spec handle_webhook(binary(), binary()) ::
          {:ok, CallView.t() | nil, :applied | :duplicate | :ignored} | {:error, atom()}
  def handle_webhook(body, authorization) do
    with {:ok, %VerifiedProviderEvent{event: event, adapter: adapter}} <-
           ProviderWebhookPort.verify_webhook(body, authorization) do
      Lifecycle.callback(event, adapter)
    end
  end

  @spec claim_dispatch(String.t(), module()) ::
          {:ok, ProviderCommand.t() | atom() | {:not_ready, pos_integer()}} | {:error, atom()}
  defdelegate claim_dispatch(id, caller), to: Lifecycle

  @spec complete_dispatch(String.t(), :pending | {:ok, map()} | {:error, atom()}, module()) ::
          {:ok, atom()} | {:error, atom()}
  defdelegate complete_dispatch(id, result, caller), to: Lifecycle

  @spec expire(String.t(), module()) ::
          {:ok, atom() | {:not_due, pos_integer()}} | {:error, atom()}
  defdelegate expire(id, caller), to: Lifecycle

  @spec claim_cleanup(String.t(), module()) ::
          {:ok, ProviderCommand.t() | :already_clean | {:not_due, pos_integer()}}
          | {:error, atom()}
  defdelegate claim_cleanup(id, caller), to: Lifecycle

  @spec complete_cleanup(String.t(), :ok | {:error, atom()}, module()) ::
          :ok | {:ok, {:not_due, pos_integer()}} | {:error, atom()}
  defdelegate complete_cleanup(id, result, caller), to: Lifecycle

  @spec revoke_identity_access(CommsCore.Accounts.CallLifecycleCommand.t()) ::
          {:ok, CommsCore.Accounts.CallLifecycleReceipt.t()} | {:error, atom()}
  defdelegate revoke_identity_access(command), to: Lifecycle

  @spec revoke_tenant_media(CommsCore.Administration.CallLifecycleCommand.t()) ::
          {:ok, CommsCore.Administration.CallLifecycleReceipt.t()} | {:error, atom()}
  defdelegate revoke_tenant_media(command), to: Lifecycle
end
