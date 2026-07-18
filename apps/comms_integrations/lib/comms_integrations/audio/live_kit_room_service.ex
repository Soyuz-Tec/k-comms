defmodule CommsIntegrations.Audio.LiveKitRoomService do
  alias CommsIntegrations.Audio.LiveKitToken

  @timeout_ms 5_000
  @delete_room_path "/twirp/livekit.RoomService/DeleteRoom"
  @remove_participant_path "/twirp/livekit.RoomService/RemoveParticipant"

  def delete_room(provider_room), do: delete_room(provider_room, &request/1)

  def delete_room(provider_room, requester)
      when is_binary(provider_room) and is_function(requester, 1) do
    with {:ok, credential} <- LiveKitToken.issue_room_control(provider_room),
         {:ok, body} <- Jason.encode(%{room: credential.room}),
         request <-
           Finch.build(
             :post,
             String.trim_trailing(credential.api_url, "/") <> @delete_room_path,
             [
               {"authorization", "Bearer " <> credential.token},
               {"content-type", "application/json"}
             ],
             body
           ),
         {:ok, response} <- requester.(request) do
      classify(response)
    else
      _ -> {:error, :audio_provider_unavailable}
    end
  end

  def delete_room(_, _), do: {:error, :audio_provider_unavailable}

  def remove_participant(provider_room, identity),
    do: remove_participant(provider_room, identity, &request/1)

  def remove_participant(provider_room, identity, requester)
      when is_binary(provider_room) and is_binary(identity) and is_function(requester, 1) do
    with true <- String.trim(identity) != "",
         {:ok, credential} <- LiveKitToken.issue_room_admin(provider_room),
         {:ok, body} <- Jason.encode(%{room: credential.room, identity: identity}),
         request <-
           Finch.build(
             :post,
             String.trim_trailing(credential.api_url, "/") <> @remove_participant_path,
             [
               {"authorization", "Bearer " <> credential.token},
               {"content-type", "application/json"}
             ],
             body
           ),
         {:ok, response} <- requester.(request) do
      classify(response)
    else
      _ -> {:error, :audio_provider_unavailable}
    end
  end

  def remove_participant(_, _, _), do: {:error, :audio_provider_unavailable}

  defp request(request) do
    Finch.request(request, CommsIntegrations.Finch, receive_timeout: @timeout_ms)
  end

  defp classify(%Finch.Response{status: status}) when status in 200..299, do: :ok
  defp classify(%Finch.Response{status: 404}), do: :ok

  defp classify(%Finch.Response{body: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"code" => "not_found"}} -> :ok
      _ -> {:error, :audio_provider_unavailable}
    end
  end

  defp classify(_), do: {:error, :audio_provider_unavailable}
end
