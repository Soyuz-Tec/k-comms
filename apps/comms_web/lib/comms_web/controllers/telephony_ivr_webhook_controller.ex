defmodule CommsWeb.TelephonyIvrWebhookController do
  use CommsWeb, :controller
  alias CommsCore.Telephony

  def create(conn, _params) do
    with [authorization] <- get_req_header(conn, "authorization"),
         body when is_binary(body) <- conn.private[:telephony_ivr_webhook_body],
         {:ok, _} <- Telephony.handle_ivr_webhook(body, authorization) do
      json(conn, %{data: %{accepted: true}})
    else
      # A verified event for a removed or expired retained run cannot resurrect
      # a caller. Acknowledge it without disclosing the resource's existence.
      {:error, :not_found} -> json(conn, %{data: %{accepted: true}})
      {:error, _} = error -> error
      _ -> {:error, :invalid_provider_webhook}
    end
  end
end
