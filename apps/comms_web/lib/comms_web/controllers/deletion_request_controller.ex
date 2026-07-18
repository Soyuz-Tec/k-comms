defmodule CommsWeb.DeletionRequestController do
  use CommsWeb, :controller

  alias CommsCore.Governance
  alias CommsWeb.ControllerHelpers

  def index(conn, params) do
    with {:ok, requests} <-
           Governance.list_deletion_request_views(params, conn.assigns.current_subject) do
      json(conn, %{data: Enum.map(requests, &Presenter.deletion_request/1)})
    end
  end

  def create(conn, params) do
    params = ControllerHelpers.with_idempotency_key(conn, params)

    with {:ok, result} <-
           Governance.create_deletion_request_view(params, conn.assigns.current_subject) do
      conn
      |> put_status(if(result.replayed, do: :ok, else: :created))
      |> json(%{data: Presenter.deletion_request(result.request), replayed: result.replayed})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, request} <-
           Governance.transition_deletion_request_view(id, params, conn.assigns.current_subject) do
      json(conn, %{data: Presenter.deletion_request(request)})
    end
  end
end
