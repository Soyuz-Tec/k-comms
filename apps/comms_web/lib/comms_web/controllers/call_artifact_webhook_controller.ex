defmodule CommsWeb.CallArtifactWebhookController do
  use CommsWeb, :controller
  alias CommsCore.AudioCalls

  def create(conn, _params) do
    with [authorization] <- get_req_header(conn, "authorization"),
         body when is_binary(body) <- conn.private[:call_artifact_webhook_body],
         {:ok, _status} <- AudioCalls.handle_artifact_callback(body, authorization) do
      json(conn, %{data: %{accepted: true}})
    else
      {:error, :unsupported_provider_event} -> json(conn, %{data: %{accepted: true}})
      {:error, _} = error -> error
      _ -> {:error, :invalid_provider_webhook}
    end
  end
end
