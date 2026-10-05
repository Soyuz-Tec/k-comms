defmodule CommsWeb.MemberWorkspaceController do
  use CommsWeb, :controller
  alias CommsCore.Accounts
  alias CommsCore.Accounts.MemberWorkspaceView

  def show(conn, _params) do
    with {:ok, view} <- Accounts.member_workspace_view(conn.assigns.current_subject) do
      private_response(conn, view)
    end
  end

  def update(conn, params) do
    with {:ok, view} <- Accounts.replace_member_workspace(params, conn.assigns.current_subject) do
      private_response(conn, view)
    end
  end

  def onboarding(conn, params) do
    with {:ok, view} <- Accounts.update_member_onboarding(params, conn.assigns.current_subject) do
      private_response(conn, view)
    end
  end

  defp private_response(conn, view) do
    conn |> put_resp_header("cache-control", "no-store") |> json(%{data: present(view)})
  end

  defp present(%MemberWorkspaceView{} = view) do
    view
    |> Map.from_struct()
    |> Map.update!(:contacts, fn contacts ->
      Enum.map(contacts, fn person -> %{id: person.id, display_name: person.display_name} end)
    end)
  end
end
