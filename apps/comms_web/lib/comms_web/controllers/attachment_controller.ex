defmodule CommsWeb.AttachmentController do
  use CommsWeb, :controller

  alias CommsCore.Attachments
  alias CommsIntegrations.ObjectStorage

  def create(conn, params) do
    with {:ok, attachment} <- Attachments.create_intent(params, conn.assigns.current_subject),
         {:ok, upload} <- ObjectStorage.presign_upload(attachment) do
      conn
      |> put_status(:created)
      |> json(%{data: Presenter.attachment(attachment), upload: upload})
    end
  end

  def complete(conn, %{"id" => id} = params) do
    with {:ok, pending} <- Attachments.get_authorized(id, conn.assigns.current_subject),
         true <- pending.status == :pending || {:error, :attachment_not_pending},
         :ok <- ObjectStorage.verify_upload(pending),
         {:ok, attachment} <-
           Attachments.mark_uploaded(id, params["checksum_sha256"], conn.assigns.current_subject) do
      json(conn, %{data: Presenter.attachment(attachment)})
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, attachment} <- Attachments.get_authorized(id, conn.assigns.current_subject),
         true <- attachment.status == :ready || {:error, :attachment_not_ready},
         {:ok, download} <- ObjectStorage.presign_download(attachment) do
      json(conn, %{data: Presenter.attachment(attachment), download: download})
    end
  end
end
