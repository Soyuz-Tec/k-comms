defmodule CommsWeb.WhiteboardLibraryController do
  use CommsWeb, :controller
  alias CommsCore.Whiteboards
  alias CommsWeb.{Broadcast, Presenter}
  alias CommsIntegrations.ObjectStorage

  def index(conn, params) do
    with {:ok, page} <- Whiteboards.gallery(conn.assigns.current_subject, params) do
      json(conn, %{data: Enum.map(page.boards, &plain/1), page: %{truncated: page.truncated}})
    end
  end

  def rename(conn, %{"conversation_id" => id} = params) do
    with {:ok, board} <- Whiteboards.rename(id, params, conn.assigns.current_subject),
         do: json(conn, %{data: plain(board)})
  end

  def versions(conn, %{"conversation_id" => id}) do
    with {:ok, versions} <- Whiteboards.versions(id, conn.assigns.current_subject),
         do: json(conn, %{data: Enum.map(versions, &plain/1)})
  end

  def checkpoint(conn, %{"conversation_id" => id} = params) do
    with {:ok, version} <- Whiteboards.checkpoint(id, params, conn.assigns.current_subject),
         do: conn |> put_status(:created) |> json(%{data: plain(version)})
  end

  def restore(conn, %{"conversation_id" => id, "version_id" => version_id} = params) do
    with {:ok, board} <- Whiteboards.restore(id, version_id, params, conn.assigns.current_subject) do
      with {:ok, page} <-
             Whiteboards.list_operations(id, conn.assigns.current_subject,
               after_sequence: params["expected_sequence"],
               limit: 500
             ) do
        Enum.each(page.operations, fn operation ->
          Broadcast.whiteboard_event(
            id,
            "whiteboard.operation_applied.v1",
            Presenter.whiteboard_operation(operation)
          )
        end)
      end

      json(conn, %{data: plain(board)})
    end
  end

  def export(conn, %{"conversation_id" => id}) do
    with {:ok, scene} <- Whiteboards.export(id, conn.assigns.current_subject) do
      json(conn, %{data: Map.update!(scene, :assets, &Enum.map(&1, fn asset -> plain(asset) end))})
    end
  end

  def create_asset(conn, %{"conversation_id" => id, "attachment_id" => attachment_id}) do
    with {:ok, asset} <- Whiteboards.add_asset(id, attachment_id, conn.assigns.current_subject),
         do: conn |> put_status(:created) |> json(%{data: plain(asset)})
  end

  def asset(conn, %{"conversation_id" => id, "asset_id" => asset_id}) do
    with {:ok, receipt} <- Whiteboards.asset_download(id, asset_id, conn.assigns.current_subject),
         {:ok, download} <- ObjectStorage.presign_download(receipt) do
      json(conn, %{
        data: %{id: asset_id, content_type: receipt.content_type, byte_size: receipt.byte_size},
        download: download
      })
    end
  end

  defp plain(%_{} = value), do: Map.from_struct(value)
end
