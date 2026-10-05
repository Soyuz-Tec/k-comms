defmodule CommsCore.Accounts.MatrixProvisioningPort do
  @moduledoc "IdentityAccess-owned, explicitly composed Synapse authentication port. No implementation may generate or receive message encryption keys."
  alias CommsCore.Accounts.{MatrixProvisioningCommand, MatrixProvisioningReceipt}

  @spec execute(atom(), MatrixProvisioningCommand.t()) ::
          {:ok, MatrixProvisioningReceipt.t()} | {:error, atom()}
  def execute(action, %MatrixProvisioningCommand{} = command)
      when action in [:provision, :login, :refresh, :revoke, :upload_public_signing_keys] do
    with true <-
           action == :revoke or
             Application.get_env(:comms_core, :matrix_client_provisioning_enabled, false),
         {:ok, adapter} <- Application.fetch_env(:comms_core, :matrix_provisioning_adapter),
         true <-
           is_atom(adapter) and Code.ensure_loaded?(adapter) and
             function_exported?(adapter, :execute, 2) do
      adapter.execute(action, command)
    else
      _ -> {:error, :matrix_provisioning_unavailable}
    end
  end
end
