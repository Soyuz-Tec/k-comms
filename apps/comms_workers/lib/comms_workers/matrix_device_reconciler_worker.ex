defmodule CommsWorkers.MatrixDeviceReconcilerWorker do
  @moduledoc "Bounded current-session/device withdrawal and unknown login cleanup through native Synapse device revocation."
  use Oban.Worker,
    queue: :lifecycle,
    max_attempts: 20,
    unique: [period: 55, fields: [:worker], states: :incomplete]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when args == %{} do
    case CommsCore.Accounts.reconcile_matrix_devices(__MODULE__) do
      {:ok, %{scanned: _, revoked: _}} -> :ok
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :matrix_device_cleanup_unconfirmed}
    end
  end

  def perform(_), do: {:discard, :invalid_matrix_cleanup_job}
end
