defmodule CommsWeb.RolePermissionController do
  use CommsWeb, :controller
  alias CommsCore.Accounts

  def index(conn, _params) do
    with {:ok, roles} <- Accounts.list_fixed_role_permissions(conn.assigns.current_subject) do
      json(conn, %{
        data:
          Enum.map(roles, fn role ->
            %{role: role.role, capabilities: Enum.map(role.capabilities, &capability/1)}
          end)
      })
    end
  end

  def preview(conn, %{"id" => id} = params) do
    with {:ok, preview} <-
           Accounts.preview_user_role_change(id, params, conn.assigns.current_subject) do
      data =
        preview
        |> Map.from_struct()
        |> Map.update!(:added, &Enum.map(&1, fn fact -> capability(fact) end))
        |> Map.update!(:removed, &Enum.map(&1, fn fact -> capability(fact) end))

      json(conn, %{data: data})
    end
  end

  defp capability(%Accounts.RoleCapabilityView{} = fact),
    do: %{capability: fact.capability, scope: fact.scope, conditions: fact.conditions}
end
