defmodule CommsWeb.GuestToken do
  @moduledoc """
  Short-lived access token for a single admitted guest conversation.

  Guest tokens use a salt that is deliberately distinct from member access
  tokens and bind all three revocable authorities: the IdentityAccess session,
  the Conversations admission, and the one allowed conversation.
  """

  alias CommsCore.{Accounts, Conversations}

  @salt "k-comms-guest-access-v1"
  @default_ttl_seconds 900

  def issue(authentication, conversation, admission, capabilities \\ []) do
    issue(authentication, %{
      conversation_id: value(conversation, :id),
      admission_id: value(admission, :id),
      expires_at: value(admission, :expires_at),
      capabilities: capabilities
    })
  end

  def issue(authentication, scope) when is_map(authentication) and is_map(scope) do
    session_id = value(authentication, :session_id)
    conversation_id = value(scope, :conversation_id)
    admission_id = value(scope, :admission_id)

    with true <- value(value(authentication, :user), :account_type) in [:guest, "guest"],
         true <- valid_id?(session_id),
         true <- valid_id?(conversation_id),
         true <- valid_id?(admission_id) do
      claims = %{
        "session_id" => session_id,
        "conversation_id" => conversation_id,
        "admission_id" => admission_id
      }

      token = Phoenix.Token.sign(CommsWeb.Endpoint, @salt, claims)

      {:ok,
       %{
         access_token: token,
         token_type: "Bearer",
         expires_in: expires_in(value(scope, :expires_at))
       }}
    else
      _ -> {:error, :invalid_guest_scope}
    end
  end

  def issue(_, _), do: {:error, :invalid_guest_scope}

  def verify(token, request_id \\ nil)

  def verify(token, request_id) when is_binary(token) do
    with {:ok,
          %{
            "session_id" => session_id,
            "conversation_id" => conversation_id,
            "admission_id" => admission_id
          } = claims} <-
           Phoenix.Token.verify(CommsWeb.Endpoint, @salt, token, max_age: token_ttl()),
         true <- valid_id?(session_id),
         true <- valid_id?(conversation_id),
         true <- valid_id?(admission_id),
         {:ok, context} <- Accounts.guest_access_context(session_id, request_id),
         true <- guest_context?(context),
         {:ok, access} <- Conversations.resolve_guest_access(context.subject, conversation_id),
         true <- access_matches?(access, context, conversation_id, admission_id) do
      {:ok, %{context: context, access: access, claims: claims}}
    else
      _ ->
        CommsObservability.execute([:auth, :failure], %{count: 1})
        {:error, :invalid_guest_access_token}
    end
  end

  def verify(_, _), do: {:error, :invalid_guest_access_token}

  defp access_matches?(access, context, conversation_id, admission_id) do
    value(access, :conversation_id) == conversation_id and
      value(access, :admission_id) == admission_id and
      value(access, :tenant_id) == value(context.subject, :tenant_id) and
      value(access, :user_id) == value(context.subject, :user_id)
  end

  defp guest_context?(context) do
    value(context.user, :account_type) in [:guest, "guest"] and
      value(context.subject, :account_type) in [:guest, "guest"]
  end

  defp expires_in(nil), do: token_ttl()

  defp expires_in(%DateTime{} = expires_at) do
    expires_at
    |> DateTime.diff(DateTime.utc_now(), :second)
    |> min(token_ttl())
    |> max(1)
  end

  defp expires_in(_), do: token_ttl()

  defp token_ttl do
    Application.get_env(:comms_web, :guest_access_token_ttl_seconds, @default_ttl_seconds)
    |> min(3_600)
    |> max(60)
  end

  defp valid_id?(value), do: is_binary(value) and byte_size(value) > 0

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_, _), do: nil
end
