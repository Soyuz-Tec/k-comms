defmodule CommsWeb.AttachmentSafetyController do
  use CommsWeb, :controller

  alias CommsCore.Attachments
  alias CommsWeb.IntegrationPresenter

  def index(conn, params) do
    with {:ok, attachments} <- Attachments.list_safety(conn.assigns.current_subject, params) do
      json(conn, %{data: Enum.map(attachments, &IntegrationPresenter.attachment_safety/1)})
    end
  end

  def retry(conn, %{"id" => id}) do
    with {:ok, attachment} <- Attachments.retry_scan(id, conn.assigns.current_subject) do
      conn
      |> put_status(:accepted)
      |> json(%{data: IntegrationPresenter.attachment_safety(attachment)})
    end
  end
end
