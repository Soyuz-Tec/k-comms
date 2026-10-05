defmodule CommsIntegrations.SynapsePrivateEvents do
  @behaviour CommsCore.Messaging.PrivateEventPort.Contract
  alias CommsCore.Messaging.{PrivateEventCommand, PrivateEventReceipt}
  alias CommsIntegrations.PinnedHttp
  @impl true
  def send_encrypted(%PrivateEventCommand{grant: grant, client_session: client} = command) do
    client = Map.put(client, :operation_deadline, grant.deadline)

    with true <-
           client.k_session_id == grant.session_id and
             client.matrix_user_id == grant.matrix_user_id,
         %{homeserver_url: issuer} <-
           Application.get_env(:comms_integrations, :synapse_private_rooms),
         true <- client.homeserver_url == issuer,
         path = "/_matrix/client/v3/rooms/" <> segment(grant.matrix_room_id),
         {:ok, 200, %{"event_id" => id}} <-
           request(
             client,
             :put,
             path <> "/send/m.room.encrypted/" <> segment(command.transaction_id),
             command.content
           ),
         {:ok, 200, event} <- request(client, :get, path <> "/event/" <> segment(id), nil),
         true <-
           event["type"] == "m.room.encrypted" and event["room_id"] == grant.matrix_room_id and
             event["sender"] == grant.matrix_user_id and event["content"] == command.content do
      {:ok,
       %PrivateEventReceipt{
         matrix_event_id: id,
         matrix_room_id: event["room_id"],
         matrix_sender: event["sender"],
         content: event["content"]
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :private_event_provider_receipt_invalid}
    end
  end

  defp request(client, method, path, body) do
    uri = URI.parse(client.homeserver_url)

    headers = [
      {"accept", "application/json"},
      {"content-type", "application/json"},
      {"authorization", "Bearer " <> client.access_token}
    ]

    remaining = client.operation_deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :private_operation_timeout}
    else
      result =
        case PinnedHttp.request(
               method,
               String.trim_trailing(client.homeserver_url, "/") <> path,
               headers,
               if(body, do: Jason.encode!(body), else: ""),
               allowed_hosts: [uri.host],
               allowed_ports: [uri.port || 443],
               timeout_ms: min(2500, remaining),
               deadline_ms: client.operation_deadline,
               max_response_bytes: 131_072
             ) do
          {:ok, %{status: status, body: payload}} ->
            case Jason.decode(payload) do
              {:ok, result} when is_map(result) -> {:ok, status, result}
              _ -> {:error, :private_event_provider_response_invalid}
            end

          _ ->
            {:error, :private_event_provider_unavailable}
        end

      if System.monotonic_time(:millisecond) >= client.operation_deadline,
        do: {:error, :private_operation_timeout},
        else: result
    end
  end

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
