defmodule CommsWeb.InstantRoomController do
  use CommsWeb, :controller

  alias CommsCore.{Accounts, Administration, Conversations}
  alias CommsWeb.GuestToken

  @base64url_256_pattern ~r/\A[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]\z/

  def create(conn, params) do
    with {:ok, idempotency_key} <- idempotency_key(conn),
         {:ok, actor, trusted_attrs} <- creation_actor(conn, params, idempotency_key),
         {:ok, result} <- Conversations.create_ephemeral_room(trusted_attrs, actor),
         {:ok, payload} <- creation_payload(result) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_status(if(result.replayed, do: :ok, else: :created))
      |> json(payload)
    end
  end

  def preview(conn, params) do
    with {:ok, _tenant} <- public_instant_room_tenant(),
         {:ok, token} <- join_token(params),
         {:ok, preview} <- Conversations.preview_ephemeral_room(token) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> json(%{data: Presenter.instant_room_preview(preview)})
    end
  end

  def join(conn, params) do
    with {:ok, tenant} <- public_instant_room_tenant(),
         {:ok, idempotency_key} <- idempotency_key(conn),
         {:ok, token} <- join_token(params),
         {:ok, actor, attrs} <- join_actor(conn, params, idempotency_key, tenant),
         {:ok, result} <- Conversations.join_ephemeral_room(token, attrs, actor),
         {:ok, payload} <- join_payload(result) do
      broadcast_join(result)

      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_status(if(result.replayed, do: :ok, else: :created))
      |> json(payload)
    end
  end

  defp creation_actor(conn, params, idempotency_key) do
    attrs =
      params
      |> Map.take(["display_name", "device", "title"])
      |> Map.merge(%{
        "idempotency_key" => idempotency_key,
        "request_id" => conn.assigns[:request_id]
      })

    with {:ok, tenant} <- public_instant_room_tenant() do
      trusted_attrs = Map.put(attrs, "tenant_id", tenant.id)

      resolve_actor(conn, tenant, trusted_attrs)
    end
  end

  defp join_actor(conn, params, idempotency_key, tenant) do
    attrs = join_attrs(params, conn, idempotency_key)
    resolve_actor(conn, tenant, attrs)
  end

  defp resolve_actor(%{assigns: %{current_subject: nil}}, _tenant, attrs),
    do: {:ok, :guest, attrs}

  defp resolve_actor(conn, tenant, attrs) do
    subject = conn.assigns.current_subject

    case Accounts.access_grant(subject) do
      {:ok,
       %{
         account_type: :human,
         access_scope: access_scope,
         tenant_id: tenant_id
       }}
      when tenant_id == tenant.id and access_scope in [:workspace, :conversation_only] ->
        {:ok, subject, attrs}

      {:ok, %{account_type: :human}} ->
        {:ok, :guest, guest_fallback_attrs(attrs, conn)}

      _invalid_or_stale_identity ->
        {:error, :forbidden}
    end
  end

  defp guest_fallback_attrs(attrs, conn) do
    attrs
    |> put_verified(
      "display_name",
      conn.assigns[:current_user] && conn.assigns.current_user.display_name
    )
    |> put_verified("device", verified_device_attrs(conn.assigns[:current_device]))
  end

  defp verified_device_attrs(%{name: name, platform: platform})
       when is_binary(name) and is_binary(platform),
       do: %{"name" => name, "platform" => platform}

  defp verified_device_attrs(_device), do: nil

  defp put_verified(attrs, _key, nil), do: attrs
  defp put_verified(attrs, key, value), do: Map.put(attrs, key, value)

  defp public_instant_room_tenant do
    with true <- Application.get_env(:comms_core, :instant_rooms_enabled, false),
         slug when is_binary(slug) <-
           Application.get_env(:comms_core, :instant_room_tenant_slug),
         true <- String.trim(slug) != "",
         {:ok, tenant} <- Administration.active_tenant_by_slug(slug) do
      {:ok, tenant}
    else
      _ -> {:error, :instant_rooms_unavailable}
    end
  end

  defp creation_payload(result) do
    base = %{
      room: Presenter.instant_room(result.room),
      conversation: Presenter.conversation(result.conversation),
      replayed: result.replayed
    }

    with_join_link(base, result)
    |> with_guest_session(result)
  end

  defp join_payload(result) do
    base = %{
      room: Presenter.instant_room(result.room),
      conversation: Presenter.conversation(result.conversation),
      replayed: result.replayed
    }

    with_guest_session(base, result)
  end

  defp broadcast_join(%{
         membership_changed: true,
         conversation: conversation,
         membership: membership
       }) do
    CommsWeb.Broadcast.event(conversation.id, "membership.changed.v1", %{
      user_id: membership.user_id,
      action: "added",
      role: membership.role,
      source: "guest_link"
    })
  end

  defp broadcast_join(_result), do: :ok

  defp with_join_link(payload, %{join_token: token}) when is_binary(token) do
    Map.merge(payload, %{token: token, share_url: share_url(token)})
  end

  defp with_join_link(payload, _result), do: payload

  defp with_guest_session(payload, %{
         authentication: authentication,
         admission: admission,
         capabilities: capabilities,
         conversation: conversation
       })
       when not is_nil(authentication) and not is_nil(admission) do
    capabilities = Map.put(capabilities, :self_service_conversion, true)

    with {:ok, token_payload} <-
           GuestToken.issue(authentication, conversation, admission, capabilities) do
      {:ok,
       Map.merge(payload, token_payload)
       |> Map.merge(%{
         refresh_token: authentication.refresh_token,
         tenant: Presenter.tenant(authentication.tenant),
         user: Presenter.guest_identity(authentication.user),
         device: Presenter.device(authentication.device),
         admission: Presenter.guest_admission(admission),
         capabilities: Presenter.guest_capabilities(capabilities)
       })}
    end
  end

  defp with_guest_session(payload, _result), do: {:ok, payload}

  defp join_attrs(params, conn, idempotency_key) do
    params
    |> Map.take(["display_name", "device"])
    |> Map.merge(%{
      "idempotency_key" => idempotency_key,
      "request_id" => conn.assigns[:request_id]
    })
  end

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key] ->
        if Regex.match?(@base64url_256_pattern, key),
          do: {:ok, key},
          else: {:error, :invalid_idempotency_key}

      [] ->
        {:error, :idempotency_key_required}

      _ ->
        {:error, :invalid_idempotency_key}
    end
  end

  defp join_token(params) do
    case params["token"] || params["code"] do
      token when is_binary(token) ->
        if Regex.match?(@base64url_256_pattern, token),
          do: {:ok, token},
          else: {:error, :ephemeral_room_unavailable}

      _ ->
        {:error, :ephemeral_room_unavailable}
    end
  end

  defp share_url(token) do
    CommsWeb.PublicShareURL.build(token)
  end
end
