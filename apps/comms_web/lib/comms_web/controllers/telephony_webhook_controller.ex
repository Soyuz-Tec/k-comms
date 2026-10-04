defmodule CommsWeb.TelephonyWebhookController do
  use CommsWeb, :controller

  alias CommsCore.Telephony

  def create(conn, _params) do
    with [authorization] <- get_req_header(conn, "authorization"),
         body when is_binary(body) <- conn.private[:telephony_webhook_body],
         {:ok, _call, _status} <- Telephony.handle_webhook(body, authorization) do
      json(conn, %{data: %{accepted: true}})
    else
      {:error, :unsupported_provider_event} -> json(conn, %{data: %{accepted: true}})
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_provider_webhook}
    end
  end
end
