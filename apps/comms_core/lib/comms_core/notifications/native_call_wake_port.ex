defmodule CommsCore.Notifications.NativeCallWakePort do
  @moduledoc "Call owner composition port; Notifications owns no foreign call persistence."
  alias CommsCore.Notifications.{NativeCallRequest, NativeCallTarget}
  alias CommsCore.Repo
  @spec recipients(NativeCallTarget.t()) :: {:ok, [binary()]} | {:error, atom()}
  def recipients(%NativeCallTarget{} = target) do
    if Repo.in_transaction?() do
      invoke(:recipients, [target])
    else
      {:error, :transaction_required}
    end
  end
  @spec authorize(NativeCallRequest.t()) :: {:ok, DateTime.t()} | {:error, atom()}
  def authorize(%NativeCallRequest{} = request) do
    if Repo.in_transaction?() do
      invoke(:authorize, [request])
    else
      {:error, :transaction_required}
    end
  end
  @spec admit(NativeCallRequest.t(), map(), function()) :: {:ok, map()} | {:error, atom()}
  def admit(%NativeCallRequest{} = request, subject, issuer) do
    if Repo.in_transaction?() do
      invoke(:admit, [request, subject, issuer])
    else
      {:error, :transaction_required}
    end
  end
  defp invoke(method, args) do
    with {:ok, adapter} <- Application.fetch_env(:comms_core, :native_call_wake_adapter),
         true <- is_atom(adapter) and Code.ensure_loaded?(adapter),
         true <- function_exported?(adapter, method, length(args)) do
      apply(adapter, method, args)
    else
      _ -> {:error, :native_push_unavailable}
    end
  end
end
