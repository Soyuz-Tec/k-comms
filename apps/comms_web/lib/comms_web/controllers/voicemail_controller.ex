defmodule CommsWeb.VoicemailController do
  use CommsWeb, :controller
  alias CommsCore.Telephony
  alias CommsWeb.VoicemailPresenter
  plug(:no_store)

  plug(
    CommsWeb.Plugs.RequireSecureTransport
    when action in [:save_mailbox, :delete, :read, :playback]
  )

  def index(conn, params) do
    with {:ok, result} <- Telephony.list_voicemails(conn.assigns.current_subject, params) do
      json(conn, %{
        data: Enum.map(result.messages, &VoicemailPresenter.message/1),
        page: Map.take(result, [:limit, :has_more, :next_cursor]),
        configured: result.configured
      })
    end
  end

  def playback(conn, %{"id" => id}) do
    with {:ok, signed} <- Telephony.voicemail_playback(id, conn.assigns.current_subject),
         do: json(conn, %{data: VoicemailPresenter.playback(signed)})
  end

  def read(conn, %{"id" => id}) do
    with {:ok, message} <- Telephony.mark_voicemail_read(id, conn.assigns.current_subject),
         do: json(conn, %{data: VoicemailPresenter.message(message)})
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, _} <- Telephony.delete_voicemail(id, conn.assigns.current_subject),
         do: conn |> put_status(:accepted) |> json(%{data: %{status: "deleting"}})
  end

  def mailbox(conn, _params) do
    with {:ok, result} <- Telephony.mailbox_config(conn.assigns.current_subject),
         do: json(conn, %{data: result.mailbox})
  end

  def save_mailbox(conn, params) do
    with {:ok, result} <- Telephony.save_mailbox(params, conn.assigns.current_subject),
         do: json(conn, %{data: result})
  end

  defp no_store(conn, _), do: put_resp_header(conn, "cache-control", "no-store")
end
