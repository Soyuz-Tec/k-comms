defmodule CommsWeb.LegalHoldController do
  use CommsWeb, :controller

  alias CommsCore.Governance
  alias CommsWeb.ControllerHelpers

  def index(conn, params) do
    with {:ok, holds} <- Governance.list_legal_holds(params, conn.assigns.current_subject) do
      json(conn, %{data: Enum.map(holds, &Presenter.legal_hold/1)})
    end
  end

  def create(conn, params) do
    params = ControllerHelpers.with_idempotency_key(conn, params)

    with {:ok, result} <- Governance.create_legal_hold(params, conn.assigns.current_subject) do
      conn
      |> put_status(if(result.replayed, do: :ok, else: :created))
      |> json(%{data: Presenter.legal_hold(result.hold), replayed: result.replayed})
    end
  end

  def release(conn, %{"id" => id} = params) do
    with {:ok, hold} <- Governance.release_legal_hold(id, params, conn.assigns.current_subject) do
      json(conn, %{data: Presenter.legal_hold(hold)})
    end
  end
end
