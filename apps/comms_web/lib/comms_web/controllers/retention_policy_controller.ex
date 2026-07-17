defmodule CommsWeb.RetentionPolicyController do
  use CommsWeb, :controller

  alias CommsCore.Governance
  alias CommsWeb.ControllerHelpers

  def index(conn, params) do
    with {:ok, policies} <-
           Governance.list_retention_policy_views(params, conn.assigns.current_subject) do
      json(conn, %{data: Enum.map(policies, &Presenter.retention_policy/1)})
    end
  end

  def create(conn, params) do
    params = ControllerHelpers.with_idempotency_key(conn, params)

    with {:ok, result} <-
           Governance.create_retention_policy_view(params, conn.assigns.current_subject) do
      conn
      |> put_status(if(result.replayed, do: :ok, else: :created))
      |> json(%{data: Presenter.retention_policy(result.policy), replayed: result.replayed})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, policy} <-
           Governance.update_retention_policy_view(id, params, conn.assigns.current_subject) do
      json(conn, %{data: Presenter.retention_policy(policy)})
    end
  end
end
