defmodule CommsWeb.UserChannel do
  @moduledoc "Content-free inbox events for a user's conversation list."

  use CommsWeb, :channel

  alias CommsCore.Accounts

  @authorized_events [
    "conversation.activity.v1",
    "conversation.membership.v1",
    "notification.available.v1"
  ]
  intercept(@authorized_events)

  @impl true
  def join("user:" <> user_id, _payload, socket) do
    case Accounts.authorize_receive_user_events(subject(socket), %{user_id: user_id}) do
      :ok -> {:ok, %{user_id: user_id}, socket}
      {:error, _} -> {:error, %{reason: "forbidden"}}
    end
  end

  @impl true
  def handle_out(event, payload, socket) when event in @authorized_events do
    case Accounts.authorize_receive_user_events(subject(socket), %{
           user_id: socket.assigns.user_id
         }) do
      :ok ->
        push(socket, event, payload)
        {:noreply, socket}

      {:error, _} ->
        {:stop, :unauthorized, socket}
    end
  end

  defp subject(socket) do
    Map.take(socket.assigns, [:tenant_id, :user_id, :device_id, :session_id, :role, :step_up_at])
  end
end
