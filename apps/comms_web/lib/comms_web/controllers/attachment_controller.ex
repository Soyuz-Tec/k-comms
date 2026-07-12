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
         {:ok, identity} <- maybe_verify_upload(pending),
         {:ok, attachment} <-
           Attachments.mark_uploaded(
             id,
             params["checksum_sha256"] || pending.checksum_sha256,
             identity,
             conn.assigns.current_subject
           ) do
      json(conn, %{data: Presenter.attachment(attachment)})
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, attachment} <- Attachments.get_authorized(id, conn.assigns.current_subject) do
      if Attachments.downloadable?(attachment) do
        with {:ok, download} <- ObjectStorage.presign_download(attachment) do
          json(conn, %{data: Presenter.attachment(attachment), download: download})
        end
      else
        json(conn, %{data: Presenter.attachment(attachment)})
      end
    end
  end

  defp maybe_verify_upload(%{status: :pending} = attachment),
    do: ObjectStorage.verify_upload(attachment)

  defp maybe_verify_upload(attachment) do
    {:ok,
     %{
       object_version_id: attachment.object_version_id,
       object_etag: attachment.object_etag,
       verified_checksum_sha256: attachment.verified_checksum_sha256
     }}
  end
end
