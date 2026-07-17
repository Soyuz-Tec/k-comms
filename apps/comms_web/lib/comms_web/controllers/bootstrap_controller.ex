defmodule CommsWeb.BootstrapController do
  use CommsWeb, :controller

  alias CommsCore.Accounts
  alias CommsWeb.Token

  def create(conn, params) do
    if Application.get_env(:comms_web, :allow_bootstrap, false) do
      with {:ok, result} <- Accounts.bootstrap_tenant_view(params) do
        conn
        |> put_status(:created)
        |> json(
          Map.put(Token.issue(result), :conversation, Presenter.conversation(result.conversation))
        )
      end
    else
      {:error, :forbidden}
    end
  end
end
