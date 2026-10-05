defmodule CommsWeb.PrivateRoomController do
  use CommsWeb, :controller
  alias CommsCore.{Accounts, Conversations, Messaging}

  def matrix_session(conn, _params) do
    with {:ok, view} <- Accounts.matrix_client_session(conn.assigns.current_subject),
         do: private(conn, Map.from_struct(view))
  end

  def signing_keys(conn, params) do
    with :ok <- Accounts.matrix_upload_public_signing_keys(params, conn.assigns.current_subject),
         do: send_resp(conn, :no_content, "")
  end

  def index(conn, _params) do
    with {:ok, rooms} <- Conversations.list_private_rooms(conn.assigns.current_subject),
         do: private(conn, Enum.map(rooms, &present_room/1))
  end

  def create(conn, params) do
    with {:ok, room} <- Conversations.create_private_room(params, conn.assigns.current_subject),
         do: private(conn, present_room(room))
  end

  def show(conn, %{"id" => id}) do
    with {:ok, room} <- Conversations.private_room(id, conn.assigns.current_subject),
         do: private(conn, present_room(room))
  end

  def remove_member(conn, %{"id" => id, "user_id" => user} = params) do
    with {:ok, room} <-
           Conversations.remove_private_room_member(
             id,
             user,
             params,
             conn.assigns.current_subject
           ),
         do: private(conn, present_room(room))
  end

  def send_event(conn, %{"id" => id} = params) do
    with {:ok, result} <- Messaging.send_private_event(id, params, conn.assigns.current_subject),
         do: private(conn, %{event: Map.from_struct(result.event), replayed: result.replayed})
  end

  def events(conn, %{"id" => id} = params) do
    params =
      Enum.reduce(["after_sequence", "membership_epoch", "generation"], params, fn field, acc ->
        Map.update(acc, field, nil, &integer/1)
      end)

    with {:ok, result} <-
           Messaging.replay_private_events(id, params, conn.assigns.current_subject),
         do:
           private(conn, %{
             result
             | events: Enum.map(result.events, &Map.from_struct/1),
               pending_intents: Enum.map(result.pending_intents, &Map.from_struct/1)
           })
  end

  defp present_room(room),
    do:
      room
      |> Map.from_struct()
      |> Map.update!(:members, &Enum.map(&1, fn member -> Map.from_struct(member) end))

  defp private(conn, data),
    do:
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("pragma", "no-cache")
      |> json(%{data: data})

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp integer(_), do: nil
end
