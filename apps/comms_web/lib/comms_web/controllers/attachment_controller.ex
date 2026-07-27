defmodule CommsWeb.AttachmentController do
  use CommsWeb, :controller

  alias CommsCore.Attachments
  alias CommsIntegrations.ObjectStorage

  def index(conn, params) do
    with {:ok, result} <- Attachments.list_files(conn.assigns.current_subject, params) do
      json(conn, %{
        data: Enum.map(result.files, &Presenter.file/1),
        page: %{
          limit: result.limit,
          has_more: result.has_more,
          next_cursor: result.next_cursor
        }
      })
    end
  end

  def create(conn, params) do
    with {:ok, attachment} <- Attachments.create_intent(params, conn.assigns.current_subject) do
      case authorize_upload(attachment, conn.assigns.current_subject) do
        {:ok, authorized, upload} ->
          conn
          |> put_status(:created)
          |> json(%{data: Presenter.attachment(authorized), upload: upload})

        {:error, reason} ->
          _ = Attachments.abandon_intent(attachment.id, conn.assigns.current_subject)
          {:error, reason}
      end
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

  def delete(conn, %{"id" => id}) do
    with {:ok, _attachment} <-
           Attachments.abandon_intent(id, conn.assigns.current_subject) do
      send_resp(conn, :no_content, "")
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

  defp authorize_upload(attachment, subject) do
    with {:ok, upload} <- ObjectStorage.presign_upload(attachment),
         {:ok, expires_at} <- upload_expiry(upload),
         {:ok, authorized} <-
           Attachments.record_upload_authorization(attachment.id, expires_at, subject) do
      {:ok, authorized, upload}
    end
  end

  defp upload_expiry(%{expires_at: %DateTime{} = expires_at}), do: {:ok, expires_at}
  defp upload_expiry(%{"expires_at" => %DateTime{} = expires_at}), do: {:ok, expires_at}

  defp upload_expiry(upload) do
    case Map.get(upload, :expires_at) || Map.get(upload, "expires_at") do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, expires_at, _offset} -> {:ok, expires_at}
          _ -> {:error, :invalid_upload_expiry}
        end

      _ ->
        {:error, :invalid_upload_expiry}
    end
  end
end
