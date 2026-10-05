defmodule CommsWeb.ScimController do
  use CommsWeb, :controller
  alias CommsCore.Accounts

  def users(conn, params), do: list(conn, params, "User")
  def groups(conn, params), do: list(conn, params, "Group")
  def user(conn, params), do: get(conn, params, "User")
  def group(conn, params), do: get(conn, params, "Group")
  def create_user(conn, params), do: create(conn, params, "User")
  def create_group(conn, params), do: create(conn, params, "Group")
  def replace_user(conn, params), do: replace(conn, params, "User")
  def replace_group(conn, params), do: replace(conn, params, "Group")
  def patch_user(conn, params), do: patch(conn, params, "User")
  def patch_group(conn, params), do: patch(conn, params, "Group")
  def delete_user(conn, params), do: delete(conn, params, "User")
  def delete_group(conn, params), do: delete(conn, params, "Group")

  def configuration(conn, _params) do
    respond(conn, Accounts.scim_configuration(conn.assigns.current_subject))
  end

  defp list(conn, params, kind),
    do: respond(conn, Accounts.scim_list(kind, params, conn.assigns.current_subject))

  defp get(conn, %{"id" => id}, kind),
    do: respond(conn, Accounts.scim_get(kind, id, conn.assigns.current_subject))

  defp create(conn, params, kind),
    do: respond(conn, Accounts.scim_create(kind, params, conn.assigns.current_subject), 201)

  defp replace(conn, %{"id" => id} = params, kind),
    do:
      respond(
        conn,
        Accounts.scim_replace(kind, id, params, version(conn), conn.assigns.current_subject)
      )

  defp patch(conn, %{"id" => id} = params, kind),
    do:
      respond(
        conn,
        Accounts.scim_patch(kind, id, params, version(conn), conn.assigns.current_subject)
      )

  defp delete(conn, %{"id" => id}, kind) do
    case Accounts.scim_delete(kind, id, version(conn), conn.assigns.current_subject) do
      {:ok, %{revoked_session_ids: ids}} ->
        disconnect(ids)
        send_resp(conn, 204, "")

      {:error, reason} ->
        failure(conn, reason)
    end
  end

  defp respond(conn, result, status \\ 200)

  defp respond(conn, {:ok, data}, status) do
    disconnect(Map.get(data, :revoked_session_ids, []))
    data = Map.delete(data, :revoked_session_ids)

    conn =
      if get_in(data, [:meta, :version]),
        do: put_resp_header(conn, "etag", data.meta.version),
        else: conn

    conn |> put_status(status) |> scim_json(data)
  end

  defp respond(conn, {:error, reason}, _status), do: failure(conn, reason)

  defp failure(conn, reason) do
    status =
      case reason do
        :forbidden -> 403
        :not_found -> 404
        :stale_version -> 412
        :last_owner_required -> 409
        :scim_identity_conflict -> 409
        _ -> 400
      end

    conn
    |> put_status(status)
    |> scim_json(%{
      schemas: ["urn:ietf:params:scim:api:messages:2.0:Error"],
      status: to_string(status),
      detail: Atom.to_string(reason)
    })
  end

  defp scim_json(conn, data),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("application/scim+json")
      |> send_resp(conn.status || 200, Jason.encode!(data))

  defp disconnect(ids),
    do:
      Enum.each(ids, fn id ->
        CommsWeb.Endpoint.broadcast("session_socket:#{id}", "disconnect", %{})
      end)

  defp version(conn), do: List.first(get_req_header(conn, "if-match"))
end
