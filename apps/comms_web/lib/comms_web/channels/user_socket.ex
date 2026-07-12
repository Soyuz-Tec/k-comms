defmodule CommsWeb.UserSocket do
  use Phoenix.Socket

  channel("conversation:*", CommsWeb.ConversationChannel)

  @impl true
  def connect(params, socket, connect_info) do
    case CommsWeb.Auth.authenticate(params, connect_info) do
      {:ok, identity} ->
        socket =
          Enum.reduce(identity, socket, fn {key, value}, acc -> assign(acc, key, value) end)

        {:ok, socket}

      _ ->
        :error
    end
  end

  @impl true
  def id(socket), do: "session_socket:#{socket.assigns.session_id}"
end
