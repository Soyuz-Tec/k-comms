defmodule CommsWeb.FederationController do
  use CommsWeb, :controller
  alias CommsCore.Conversations
  alias CommsCore.Conversations.Federation.View
  plug(:private_response)
  plug(:validate_conversation_id)

  def trusts(conn, _),
    do: respond(conn, Conversations.federation_trusts(conn.assigns.current_subject))

  def policy(conn, params),
    do: respond(conn, Conversations.put_federation_trust(params, conn.assigns.current_subject))

  def show(conn, %{"conversation_id" => id}),
    do: respond(conn, Conversations.federation_room(id, conn.assigns.current_subject))

  def create(conn, %{"conversation_id" => id} = params),
    do:
      respond(
        conn,
        Conversations.create_federation_room(id, params, conn.assigns.current_subject),
        202
      )

  def consent(conn, %{"conversation_id" => id} = params),
    do: respond(conn, Conversations.federation_consent(id, params, conn.assigns.current_subject))

  def invite(conn, %{"conversation_id" => id} = params),
    do:
      respond(
        conn,
        Conversations.invite_federation_participant(id, params, conn.assigns.current_subject),
        202
      )

  def send_message(conn, %{"conversation_id" => id} = params),
    do:
      respond(
        conn,
        Conversations.send_federation_message(id, params, conn.assigns.current_subject),
        202
      )

  def export_metadata(conn, %{"conversation_id" => id}),
    do: respond(conn, Conversations.export_federation_metadata(id, conn.assigns.current_subject))

  def timeline(conn, %{"conversation_id" => id} = params),
    do: respond(conn, Conversations.federation_timeline(id, params, conn.assigns.current_subject))

  def close(conn, %{"conversation_id" => id} = params),
    do:
      respond(
        conn,
        Conversations.close_federation_room(id, params, conn.assigns.current_subject),
        202
      )

  defp respond(conn, result, status \\ 200)

  defp respond(conn, {:ok, result}, status),
    do: conn |> put_status(status) |> json(%{data: present(result)})

  defp respond(conn, {:error, reason}, _)
       when reason in [
              :forbidden,
              :not_found,
              :stale_version,
              :step_up_required,
              :legal_hold_active
            ],
       do: CommsWeb.FallbackController.call(conn, {:error, reason})

  defp respond(conn, {:error, reason}, _) do
    status =
      cond do
        reason in [
          :federation_disabled,
          :federation_not_configured,
          :matrix_identity_not_ready,
          :federation_deadline
        ] ->
          503

        reason in [:federation_quota, :matrix_rate_limited] ->
          429

        reason in [
          :invalid_federation_domain,
          :invalid_federation_policy,
          :invalid_federation_text,
          :plaintext_disclosure_required,
          :untrusted_matrix_principal,
          :invalid_federation_cursor
        ] ->
          422

        true ->
          409
      end

    conn
    |> put_status(status)
    |> json(%{
      error: %{
        code: Atom.to_string(reason),
        detail: "Federation cannot complete this request in its current state"
      }
    })
  end

  defp present(%View{} = view), do: Map.from_struct(view)
  defp present(value), do: value

  defp validate_conversation_id(%{params: %{"conversation_id" => id}} = conn, _) do
    case Ecto.UUID.cast(id) do
      {:ok, _} ->
        conn

      _ ->
        conn
        |> put_status(422)
        |> json(%{
          error: %{
            code: "invalid_conversation_id",
            detail: "A valid conversation identifier is required"
          }
        })
        |> halt()
    end
  end

  defp validate_conversation_id(conn, _), do: conn

  defp private_response(conn, _),
    do:
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("pragma", "no-cache")
end
