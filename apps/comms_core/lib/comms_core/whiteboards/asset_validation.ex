defmodule CommsCore.Whiteboards.AssetValidation do
  @moduledoc false
  alias CommsCore.Repo
  alias CommsCore.Whiteboards.{Asset, BoardAssetPort, Whiteboard}

  @spec validate(Whiteboard.t(), [map()], map()) :: :ok | {:error, :asset_unavailable}
  def validate(board, elements, subject) do
    Enum.reduce_while(elements, :ok, fn element, :ok ->
      if element["type"] == "image" and element["isDeleted"] != true do
        case Repo.get_by(Asset,
               id: element["fileId"],
               whiteboard_id: board.id,
               tenant_id: board.tenant_id
             ) do
          %Asset{} = asset ->
            case BoardAssetPort.read(
                   asset.attachment_id,
                   asset.source_message_id,
                   board.conversation_id,
                   subject
                 ) do
              {:ok, _} -> {:cont, :ok}
              {:error, _} -> {:halt, {:error, :asset_unavailable}}
            end

          nil ->
            {:halt, {:error, :asset_unavailable}}
        end
      else
        {:cont, :ok}
      end
    end)
  end
end
