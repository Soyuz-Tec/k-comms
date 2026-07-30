defmodule CommsCore.Messaging do
  @moduledoc """
  Public ConversationContent facade for durable messaging operations.

  Commands, authorized reads, search, reactions, service access, and
  governance contributions remain owner-internal implementation details.
  """

  import Ecto.Query

  alias CommsCore.Messaging.{
    GovernanceQueries,
    History,
    Message,
    MessageCommands,
    Reactions,
    Search,
    ServiceMessages
  }

  @doc false
  def release_tenant_fingerprint_fragment(repo, tenant_id)
      when is_atom(repo) and is_binary(tenant_id) do
    %{
      messages:
        repo.all(
          from(message in Message,
            where: message.tenant_id == ^tenant_id,
            select: message.id
          )
        )
    }
  end

  defdelegate governance_impact(tenant_id, target_type, target_id), to: GovernanceQueries

  defdelegate retention_candidates(tenant_id, scopes, excluded_message_ids, limit_count),
    to: GovernanceQueries

  defdelegate tombstone_for_erasure(tenant_id, message_ids, timestamp), to: GovernanceQueries

  defdelegate list_service_history(conversation_id, subject, opts \\ []), to: ServiceMessages

  defdelegate accept_service_message_with_status(conversation_id, attrs, subject),
    to: ServiceMessages

  defdelegate search_for_service(query, subject, opts \\ []), to: ServiceMessages

  defdelegate accept_message(attrs, subject, opts \\ []), to: MessageCommands
  defdelegate accept_message_with_status(attrs, subject, opts \\ []), to: MessageCommands
  defdelegate edit_message(message_id, body, subject), to: MessageCommands
  defdelegate delete_message(message_id, subject, policy_check), to: MessageCommands

  defdelegate list_after(tenant_id, conversation_id, after_sequence \\ 0, limit \\ 100),
    to: History

  defdelegate list_history(conversation_id, subject, opts \\ []), to: History
  defdelegate list_history_page(conversation_id, subject, opts \\ []), to: History
  defdelegate refresh_sender_labels(conversation_id, message_ids, subject), to: History
  defdelegate message_event_visible?(conversation_id, message_id, subject), to: History
  defdelegate get_thread(conversation_id, message_id, subject, opts \\ []), to: History

  defdelegate add_reaction(message_id, emoji, subject), to: Reactions
  defdelegate remove_reaction(message_id, emoji, subject), to: Reactions

  defdelegate search(query_text, subject, opts \\ []), to: Search
  defdelegate search_page(query_text, subject, opts \\ []), to: Search
end
