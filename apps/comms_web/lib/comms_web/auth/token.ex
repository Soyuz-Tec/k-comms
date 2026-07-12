defmodule CommsWeb.Auth.Token do
  @behaviour CommsWeb.Auth

  @impl true
  def authenticate(params, _connect_info) do
    token = params["access_token"] || params[:access_token]

    case CommsWeb.Token.verify(token) do
      {:ok, context} -> {:ok, context.subject}
      {:error, _} = error -> error
    end
  end
end
