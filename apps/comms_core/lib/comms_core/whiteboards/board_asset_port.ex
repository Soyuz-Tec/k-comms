defmodule CommsCore.Whiteboards.BoardAssetPort do
  @moduledoc "Collaboration-owned contract for retaining only approved conversation content assets."
  alias CommsCore.Whiteboards.BoardAssetReceipt
  @callback claim(binary(), binary(), map()) :: {:ok, BoardAssetReceipt.t()} | {:error, atom()}
  @callback read(binary(), binary(), binary(), map()) ::
              {:ok, BoardAssetReceipt.t()} | {:error, atom()}
  @spec claim(binary(), binary(), map()) :: {:ok, BoardAssetReceipt.t()} | {:error, atom()}
  def claim(attachment_id, conversation_id, subject),
    do: adapter().claim(attachment_id, conversation_id, subject)

  @spec read(binary(), binary(), binary(), map()) ::
          {:ok, BoardAssetReceipt.t()} | {:error, atom()}
  def read(attachment_id, source_message_id, conversation_id, subject),
    do: adapter().read(attachment_id, source_message_id, conversation_id, subject)

  defp adapter, do: Application.fetch_env!(:comms_core, :whiteboard_asset_adapter)
end
