defmodule CommsCore.Messaging.ServiceMessages do
  @moduledoc false

  alias CommsCore.{Conversations, ServiceAccounts}
  alias CommsCore.Messaging.{History, MessageCommands, MessageView, Search}

  @doc """
  Lists message history for an authenticated service identity.

  ConversationContent owns the query and projection. IdentityAccess validates
  service-account scope, while Conversations owns membership and archive
  authorization.
  """
  @spec list_service_history(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, [MessageView.t()]} | {:error, term()}
  def list_service_history(conversation_id, subject, opts \\ [])
      when is_binary(conversation_id) and is_map(subject) and is_list(opts) do
    with :ok <-
           Conversations.authorize_service_access(subject, "messages:read", conversation_id) do
      History.list_history(
        conversation_id,
        subject,
        Keyword.put(opts, :authorize, &service_authorizer/3)
      )
    end
  end

  @doc """
  Accepts a service-authored message through the ConversationContent owner.

  Service identities cannot attach files. Authorization is rechecked inside
  the existing message transaction so idempotent replay semantics are retained.
  """
  @spec accept_service_message_with_status(Ecto.UUID.t(), map(), map()) ::
          {:ok, MessageView.t(), :created | :duplicate} | {:error, term()}
  def accept_service_message_with_status(conversation_id, attrs, subject)
      when is_binary(conversation_id) and is_map(attrs) and is_map(subject) do
    with :ok <- reject_service_attachments(attrs),
         :ok <-
           Conversations.authorize_service_access(subject, "messages:write", conversation_id) do
      message_attrs =
        attrs
        |> Map.put(:tenant_id, value(subject, :tenant_id))
        |> Map.put(:conversation_id, conversation_id)
        |> Map.put(:sender_user_id, value(subject, :user_id))
        |> Map.put(:sender_device_id, value(subject, :device_id))
        |> Map.put(:attachment_ids, [])

      MessageCommands.accept_message_with_status(message_attrs, subject,
        authorize: &service_authorizer/3
      )
    end
  end

  @doc """
  Searches message content visible to a scoped service identity.
  """
  @spec search_for_service(String.t(), map(), keyword()) ::
          {:ok, [MessageView.t()]} | {:error, term()}
  def search_for_service(query, subject, opts \\ [])
      when is_binary(query) and is_map(subject) and is_list(opts) do
    with :ok <- ServiceAccounts.authorize_service(subject, "search:read") do
      query_text = String.trim(query)

      if query_text == "" do
        {:ok, []}
      else
        limit_count = opts |> Keyword.get(:limit, 50) |> integer(50) |> max(1) |> min(100)
        Search.search(query_text, subject, limit: limit_count)
      end
    end
  end

  defp service_authorizer(:send_message, subject, %{id: id}),
    do: Conversations.authorize_service_access(subject, "messages:write", id)

  defp service_authorizer(:read_conversation, subject, %{id: id}),
    do: Conversations.authorize_service_access(subject, "messages:read", id)

  defp service_authorizer(_, _, _), do: {:error, :forbidden}

  defp reject_service_attachments(attrs) do
    case value(attrs, :attachment_ids) do
      nil -> :ok
      [] -> :ok
      _ -> {:error, :invalid_attachments}
    end
  end

  defp integer(value, _) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> default
    end
  end

  defp integer(_, default), do: default
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
