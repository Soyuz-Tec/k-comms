defmodule CommsCore.Messaging do
  import Ecto.Query
  alias CommsCore.{Authorization, Repo}
  alias CommsCore.Audit.AuditEvent
  alias CommsCore.Conversations.Conversation
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Messaging.Message

  @required [:tenant_id, :conversation_id, :sender_user_id, :sender_device_id, :client_message_id]

  def accept_message(attrs, subject, opts \\ []) when is_map(attrs) and is_map(subject) do
    attrs = normalize(attrs)
    authorize = Keyword.get(opts, :authorize, &Authorization.authorize/3)

    with :ok <- validate(attrs) do
      Repo.transaction(fn -> accept_in_transaction(attrs, subject, authorize) end)
    end
  end

  def list_after(tenant_id, conversation_id, after_sequence \\ 0, limit \\ 100) do
    Message
    |> where([m], m.tenant_id == ^tenant_id and m.conversation_id == ^conversation_id and m.conversation_sequence > ^after_sequence)
    |> order_by([m], asc: m.conversation_sequence)
    |> limit(^min(max(limit, 1), 500))
    |> Repo.all()
  end

  defp accept_in_transaction(attrs, subject, authorize) do
    case existing(attrs) do
      %Message{} = message -> message
      nil ->
        conversation = Repo.one(from c in Conversation, where: c.id == ^attrs.conversation_id and c.tenant_id == ^attrs.tenant_id, lock: "FOR UPDATE") || Repo.rollback(:conversation_not_found)
        case authorize.(:send_message, subject, conversation) do
          :ok -> persist(attrs, subject, conversation)
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp existing(attrs) do
    Repo.one(from m in Message, where: m.tenant_id == ^attrs.tenant_id and m.sender_device_id == ^attrs.sender_device_id and m.client_message_id == ^attrs.client_message_id)
  end

  defp persist(attrs, subject, conversation) do
    sequence = conversation.next_sequence
    conversation |> Conversation.changeset(%{next_sequence: sequence + 1}) |> Repo.update!()
    message = %Message{} |> Message.changeset(Map.merge(attrs, %{conversation_sequence: sequence, status: :active})) |> Repo.insert!()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %OutboxEvent{} |> OutboxEvent.changeset(%{tenant_id: message.tenant_id, event_type: "message.created.v1", aggregate_type: "message", aggregate_id: message.id, payload: %{id: message.id, conversation_id: message.conversation_id, conversation_sequence: sequence, sender_user_id: message.sender_user_id, body: message.body}, available_at: now}) |> Repo.insert!()
    %AuditEvent{} |> AuditEvent.changeset(%{tenant_id: message.tenant_id, actor_user_id: message.sender_user_id, action: "message.create", resource_type: "message", resource_id: message.id, metadata: %{conversation_id: message.conversation_id, sequence: sequence}, request_id: Map.get(subject, :request_id)}) |> Repo.insert!()
    message
  end

  defp validate(attrs) do
    missing = Enum.filter(@required, &(Map.get(attrs, &1) in [nil, ""]))
    body = Map.get(attrs, :body)
    cond do
      missing != [] -> {:error, {:missing_fields, missing}}
      not is_binary(body) or String.trim(body) == "" -> {:error, :message_body_required}
      String.length(body) > 65_535 -> {:error, :message_too_large}
      true -> :ok
    end
  end

  defp normalize(attrs) do
    Map.new([:tenant_id, :conversation_id, :sender_user_id, :sender_device_id, :client_message_id, :body], fn key -> {key, Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))} end)
  end
end
