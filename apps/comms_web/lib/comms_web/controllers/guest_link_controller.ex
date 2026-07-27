defmodule CommsWeb.GuestLinkController do
  use CommsWeb, :controller

  alias CommsCore.Conversations

  def index(conn, %{"conversation_id" => conversation_id}) do
    with {:ok, links} <-
           Conversations.list_guest_link_views(conversation_id, conn.assigns.current_subject) do
      json(conn, %{data: Enum.map(links, &Presenter.guest_link/1)})
    end
  end

  def create(conn, %{"conversation_id" => conversation_id} = params) do
    attrs =
      params
      |> Map.take(["expires_in_seconds", "max_uses", "conversion_email"])
      |> Map.put("request_id", conn.assigns[:request_id])

    with {:ok,
          %{
            guest_link: guest_link,
            token: token,
            conversion_verification_code: conversion_verification_code
          }} <-
           Conversations.create_guest_link_view(
             conversation_id,
             attrs,
             conn.assigns.current_subject
           ) do
      data =
        guest_link
        |> Presenter.guest_link()
        |> Map.put(:share_url, share_url(token))

      payload =
        %{data: data, token: token, share_url: data.share_url}
        |> maybe_put_conversion_verification_code(conversion_verification_code)

      conn
      |> put_status(:created)
      |> json(payload)
    end
  end

  def revoke(conn, %{"conversation_id" => conversation_id, "link_id" => link_id}) do
    with {:ok, result} <-
           Conversations.revoke_guest_link_view(
             conversation_id,
             link_id,
             conn.assigns.current_subject
           ),
         {:ok, guest_link, revoked_session_ids} <- revocation_receipt(result) do
      Enum.each(revoked_session_ids, &disconnect_session/1)
      json(conn, %{data: Presenter.guest_link(guest_link)})
    end
  end

  defp revocation_receipt(%{guest_link: guest_link, revoked_session_ids: session_ids})
       when is_list(session_ids),
       do: {:ok, guest_link, Enum.uniq(session_ids)}

  defp revocation_receipt(_result), do: {:error, :guest_link_not_found}

  defp disconnect_session(session_id) when is_binary(session_id) do
    CommsWeb.Endpoint.broadcast("session_socket:#{session_id}", "disconnect", %{})
  end

  defp share_url(token) do
    CommsWeb.PublicShareURL.build(token)
  end

  defp maybe_put_conversion_verification_code(payload, code) when is_binary(code),
    do: Map.put(payload, :conversion_verification_code, code)

  defp maybe_put_conversion_verification_code(payload, _code), do: payload
end
