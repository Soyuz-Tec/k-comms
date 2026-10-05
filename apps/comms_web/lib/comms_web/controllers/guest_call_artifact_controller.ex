defmodule CommsWeb.GuestCallArtifactController do
  @moduledoc "Guests may see current recording disclosure and decide only their own admission consent."
  use CommsWeb, :controller
  alias CommsCore.AudioCalls
  plug(CommsWeb.Plugs.RequireSecureTransport)

  def index(conn, %{"call_id" => call_id}) do
    conversation_id = conn.assigns.current_guest_claims["conversation_id"]

    with {:ok, result} <-
           AudioCalls.list_artifacts(conversation_id, call_id, conn.assigns.current_subject) do
      artifacts =
        result.artifacts
        |> Enum.filter(&(&1.status in [:pending_consent, :starting, :recording, :stopping]))
        |> Enum.map(&(Map.from_struct(&1) |> Map.put(:can_manage, false)))

      capabilities = %{
        result.capabilities
        | recording: false,
          recording_reason: "guest_participant_only",
          persistent_transcript: false
      }

      conn
      |> put_resp_header("cache-control", "no-store")
      |> json(%{data: artifacts, capabilities: capabilities})
    end
  end

  def consent(conn, %{"call_id" => call_id, "id" => id, "accepted" => accepted})
      when is_boolean(accepted) do
    conversation_id = conn.assigns.current_guest_claims["conversation_id"]

    CommsWeb.CallArtifactController.consent(conn, %{
      "conversation_id" => conversation_id,
      "call_id" => call_id,
      "id" => id,
      "accepted" => accepted
    })
  end

  def consent(conn, _), do: CommsWeb.CallArtifactController.consent(conn, %{})
end
