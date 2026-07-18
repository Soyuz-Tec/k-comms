defmodule CommsWeb.ModerationController do
  use CommsWeb, :controller

  alias CommsCore.Moderation
  alias CommsWeb.ControllerHelpers

  def index(conn, params) do
    with {:ok, cases} <- Moderation.list_case_views(params, conn.assigns.current_subject) do
      json(conn, %{data: Enum.map(cases, &Presenter.moderation_case/1)})
    end
  end

  def create(conn, params) do
    params = ControllerHelpers.with_idempotency_key(conn, params)

    with {:ok, result} <- Moderation.create_case_view(params, conn.assigns.current_subject) do
      conn
      |> put_status(if(result.replayed, do: :ok, else: :created))
      |> json(%{data: Presenter.moderation_case(result.case), replayed: result.replayed})
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, result} <- Moderation.get_case_view(id, conn.assigns.current_subject) do
      json(conn, %{
        data: Presenter.moderation_case(result.case),
        actions: Enum.map(result.actions, &Presenter.moderation_action/1)
      })
    end
  end

  def add_action(conn, %{"case_id" => case_id} = params) do
    with {:ok, result} <-
           Moderation.add_action_view(case_id, params, conn.assigns.current_subject) do
      json(conn, %{
        data: Presenter.moderation_case(result.case),
        action: Presenter.moderation_action(result.action)
      })
    end
  end
end
