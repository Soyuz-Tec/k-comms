defmodule CommsWeb.InvitationController do
  use CommsWeb, :controller

  alias CommsCore.Accounts
  alias CommsWeb.ControllerHelpers

  def index(conn, params) do
    with {:ok, invitations} <-
           Accounts.list_invitations(conn.assigns.current_subject, params["status"]) do
      json(conn, %{data: Enum.map(invitations, &Presenter.invitation/1)})
    end
  end

  def create(conn, params) do
    params = ControllerHelpers.with_idempotency_key(conn, params)

    with {:ok, result} <- Accounts.create_invitation(params, conn.assigns.current_subject) do
      conn
      |> put_status(if(result.replayed, do: :ok, else: :created))
      |> json(%{
        data: Presenter.invitation(result.invitation),
        invitation_token: result.token,
        replayed: result.replayed
      })
    end
  end

  def revoke(conn, %{"id" => id} = params) do
    with {:ok, invitation} <- Accounts.revoke_invitation(id, params, conn.assigns.current_subject) do
      json(conn, %{data: Presenter.invitation(invitation)})
    end
  end

  def accept(conn, params) do
    with {:ok, user} <- Accounts.accept_invitation(params) do
      conn |> put_status(:created) |> json(%{data: Presenter.user(user)})
    end
  end
end
