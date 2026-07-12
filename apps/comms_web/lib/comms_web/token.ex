defmodule CommsWeb.Token do
  alias CommsCore.Accounts

  @salt "k-comms-access-v1"

  def issue(result) do
    ttl = Application.get_env(:comms_web, :access_token_ttl_seconds, 900)
    token = Phoenix.Token.sign(CommsWeb.Endpoint, @salt, %{"session_id" => result.session.id})

    %{
      access_token: token,
      refresh_token: result.refresh_token,
      token_type: "Bearer",
      expires_in: ttl,
      tenant: CommsWeb.Presenter.tenant(result.tenant),
      user: CommsWeb.Presenter.identity_user(result.user),
      device: CommsWeb.Presenter.device(result.device)
    }
  end

  def verify(token, request_id \\ nil)

  def verify(token, request_id) when is_binary(token) do
    ttl = Application.get_env(:comms_web, :access_token_ttl_seconds, 900)

    with {:ok, %{"session_id" => session_id}} <-
           Phoenix.Token.verify(CommsWeb.Endpoint, @salt, token, max_age: ttl),
         {:ok, session} <- Accounts.get_active_session(session_id) do
      {:ok,
       %{
         subject: Accounts.subject_for_session(session, request_id),
         session: session,
         tenant: session.tenant,
         user: session.user,
         device: session.device
       }}
    else
      _ ->
        CommsObservability.execute([:auth, :failure], %{count: 1})
        {:error, :invalid_access_token}
    end
  end

  def verify(_, _), do: {:error, :invalid_access_token}
end
