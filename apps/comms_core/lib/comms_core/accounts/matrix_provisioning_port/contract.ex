defmodule CommsCore.Accounts.MatrixProvisioningPort.Contract do
  alias CommsCore.Accounts.{MatrixProvisioningCommand, MatrixProvisioningReceipt}

  @callback execute(
              :provision | :login | :refresh | :revoke | :upload_public_signing_keys,
              MatrixProvisioningCommand.t()
            ) :: {:ok, MatrixProvisioningReceipt.t()} | {:error, atom()}
end
