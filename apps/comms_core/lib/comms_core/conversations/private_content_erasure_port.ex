defmodule CommsCore.Conversations.PrivateContentErasurePort do
  alias CommsCore.Conversations.{PrivateContentErasureCommand, PrivateContentErasureReceipt}

  @callback erase_private_content(PrivateContentErasureCommand.t()) ::
              {:ok, PrivateContentErasureReceipt.t()} | {:error, atom()}
  @spec erase_private_content(PrivateContentErasureCommand.t()) ::
          {:ok, PrivateContentErasureReceipt.t()} | {:error, atom()}
  def erase_private_content(%PrivateContentErasureCommand{} = command) do
    if CommsCore.Repo.in_transaction?() do
      with {:ok, adapter} <- Application.fetch_env(:comms_core, :private_content_erasure_adapter),
           {:ok, %PrivateContentErasureReceipt{} = receipt} <-
             adapter.erase_private_content(command),
           do: {:ok, receipt}
    else
      {:error, :transaction_required}
    end
  end
end
