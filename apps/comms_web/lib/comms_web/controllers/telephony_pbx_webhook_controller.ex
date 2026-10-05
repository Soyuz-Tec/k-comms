defmodule CommsWeb.TelephonyPBXWebhookController do
  use CommsWeb, :controller

  def create(conn, _params) do
    with [authorization] <- get_req_header(conn, "authorization"),
         body when is_binary(body) <- conn.private[:telephony_pbx_webhook_body],
         {:ok, _} <- CommsCore.Telephony.control_provider_event(body, authorization) do
      json(conn, %{data: %{accepted: true}})
    else
      {:error, :unrelated_provider_event} -> json(conn, %{data: %{accepted: true}})
      {:error, _} = error -> error
      _ -> {:error, :invalid_provider_webhook}
    end
  end
end
