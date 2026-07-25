defmodule CommsWeb.GuestSessionController do
  use CommsWeb, :controller

  alias CommsCore.{Accounts, Conversations}
  alias CommsWeb.{GuestToken, Token}

  def preview(conn, params) do
    with {:ok, token} <- guest_link_token(params),
         {:ok, preview} <- Conversations.preview_guest_link(token) do
      json(conn, %{data: Presenter.guest_preview(preview)})
    end
  end

  def create(conn, params) do
    with {:ok, token} <- guest_link_token(params),
         attrs <- redemption_attrs(params, conn),
         {:ok, result} <- Conversations.redeem_guest_link(token, attrs),
         {:ok, token_payload} <-
           GuestToken.issue(
             result.authentication,
             result.conversation,
             result.admission,
             result.capabilities
           ) do
      CommsObservability.execute(
        [:auth, :success],
        %{count: 1},
        %{tenant_id: result.authentication.tenant.id, account_type: :guest}
      )

      CommsWeb.Broadcast.event(result.conversation.id, "membership.changed.v1", %{
        user_id: result.authentication.user.id,
        action: "added",
        role: "member",
        source: "guest_link"
      })

      conn
      |> put_status(:created)
      |> json(guest_session_payload(token_payload, result))
    else
      {:error, reason} = error ->
        CommsObservability.execute(
          [:auth, :failure],
          %{count: 1},
          %{reason: reason, account_type: :guest}
        )

        error
    end
  end

  def refresh(conn, %{"refresh_token" => refresh_token}) do
    with {:ok, authentication} <- Accounts.refresh_guest_session_view(refresh_token),
         {:ok, scope} <- Conversations.guest_scope_for_session(authentication.session_id),
         {:ok, token_payload} <- GuestToken.issue(authentication, scope) do
      json(
        conn,
        guest_session_payload(token_payload, %{
          authentication: authentication,
          conversation: scope.conversation,
          admission: scope_admission(scope),
          capabilities: scope.capabilities
        })
      )
    end
  end

  def refresh(_conn, _params), do: {:error, :invalid_refresh_token}

  def convert_account(conn, params) do
    attrs =
      params
      |> Map.take(["email", "verification_code", "password", "display_name"])
      |> Map.merge(device_attrs(params["device"]))
      |> Map.put("request_id", conn.assigns[:request_id])

    with {:ok, result} <-
           Conversations.convert_guest_account(attrs, conn.assigns.current_subject) do
      ephemeral_handoff? = Map.get(result, :ephemeral_owner_upgraded, false)

      unless ephemeral_handoff? do
        CommsWeb.Endpoint.broadcast(
          "session_socket:#{conn.assigns.current_subject.session_id}",
          "disconnect",
          %{}
        )
      end

      payload = %{
        authentication: Token.issue(result.authentication),
        conversation: Presenter.conversation(result.conversation)
      }

      payload =
        if ephemeral_handoff? do
          maybe_put_socket_handoff(payload, result.authentication, conn.assigns[:request_id])
        else
          payload
        end

      json(conn, payload)
    end
  end

  def delete(conn, _params) do
    subject =
      conn.assigns.current_subject
      |> Map.put(:request_id, conn.assigns[:request_id])

    with :ok <- Conversations.logout_guest_session(subject) do
      CommsWeb.Endpoint.broadcast("session_socket:#{subject.session_id}", "disconnect", %{})
      send_resp(conn, :no_content, "")
    end
  end

  defp guest_session_payload(token_payload, result) do
    authentication = result.authentication

    Map.merge(token_payload, %{
      refresh_token: authentication.refresh_token,
      tenant: Presenter.tenant(authentication.tenant),
      user: Presenter.guest_identity(authentication.user),
      device: Presenter.device(authentication.device),
      conversation: Presenter.conversation(result.conversation),
      admission: Presenter.guest_admission(result.admission),
      capabilities: Presenter.guest_capabilities(result.capabilities)
    })
  end

  defp guest_link_token(params) do
    case params["token"] || params["code"] do
      token when is_binary(token) and byte_size(token) in 20..1_024 -> {:ok, token}
      _ -> {:error, :invalid_guest_link}
    end
  end

  defp redemption_attrs(params, conn) do
    %{
      "display_name" => params["display_name"],
      "device" => params["device"] || %{},
      "request_id" => conn.assigns[:request_id]
    }
  end

  defp device_attrs(device) when is_map(device) do
    %{
      "device_name" => device["name"] || device[:name],
      "device_platform" => device["platform"] || device[:platform]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp device_attrs(_), do: %{}

  defp scope_admission(scope) do
    %{
      id: scope.admission_id,
      conversation_id: scope.conversation_id,
      guest_link_id: Map.get(scope, :guest_link_id),
      admitted_at: scope.admitted_at,
      expires_at: scope.expires_at,
      history_from_sequence: scope.history_from_sequence,
      converted_at: Map.get(scope, :converted_at)
    }
  end

  defp maybe_put_socket_handoff(payload, authentication, request_id) do
    subject = %{
      tenant_id: authentication.tenant.id,
      user_id: authentication.user.id,
      device_id: authentication.device.id,
      session_id: authentication.session_id,
      role: authentication.user.role,
      account_type: authentication.user.account_type,
      request_id: request_id
    }

    case Accounts.issue_socket_ticket(subject) do
      {:ok, ticket} -> Map.put(payload, :socket_handoff, ticket)
      {:error, _reason} -> payload
    end
  end
end
