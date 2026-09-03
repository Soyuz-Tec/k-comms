defmodule CommsCore.Messaging do
  @moduledoc """
  Public ConversationContent facade for durable messaging operations.

  Commands, authorized reads, search, reactions, service access, and
  governance contributions remain owner-internal implementation details.
  """

  import Ecto.Query

  alias CommsCore.Messaging.{
    DeliveryCursors,
    Activity,
    GovernanceQueries,
    History,
    Message,
    MessageCommands,
    Reactions,
    Search,
    ServiceMessages
  }

  @typedoc "Scalar values allowed across this facade boundary."
  @type public_scalar ::
          atom()
          | binary()
          | boolean()
          | integer()
          | float()
          | DateTime.t()
          | NaiveDateTime.t()
          | nil

  @typedoc "Persistence-neutral structured data with scalar leaves."
  @type public_map :: %{
          optional(atom() | binary()) =>
            public_scalar() | public_map() | [public_scalar() | public_map()]
        }

  @typedoc "Named DTOs owned by this bounded context."
  @type public_contract ::
          CommsCore.Messaging.ActivityView.t()
          | CommsCore.Messaging.DeliveryCursorView.t()
          | CommsCore.Messaging.MessageView.t()
          | CommsCore.Messaging.MessageDeletionCandidate.t()
          | CommsCore.Messaging.GovernanceImpact.t()
          | CommsCore.Messaging.RetentionScope.t()
          | CommsCore.Messaging.RetentionCandidate.t()
          | CommsCore.Messaging.ReactionView.t()

  @type public_value :: public_scalar() | public_map() | public_contract()
  @type public_input ::
          public_value() | [public_value()] | function() | module()
  @type public_error ::
          atom()
          | CommsCore.ValidationError.t()
          | public_map()
          | {atom(), public_scalar() | public_map()}
  @type public_response ::
          public_value()
          | [public_value()]
          | {:ok, public_value() | [public_value()]}
          | {:error, public_error()}

  @spec accept_message_with_status(public_map(), public_map()) :: public_response()
  @spec accept_service_message_with_status(binary(), public_map(), public_map()) ::
          public_response()
  @spec activity(binary(), public_map(), keyword() | public_map()) ::
          [public_value()] | {:ok, [public_value()]} | {:error, public_error()}
  @spec add_reaction(binary(), public_input(), public_map()) :: public_response()
  @spec edit_message(binary(), public_input(), public_map()) :: public_response()
  @spec get_thread(binary(), binary(), public_map(), keyword() | public_map()) ::
          public_response()
  @spec list_delivery_cursors(binary(), public_map()) ::
          [public_value()] | {:ok, [public_value()]} | {:error, public_error()}
  @spec list_history(binary(), public_map(), keyword() | public_map()) ::
          [public_value()] | {:ok, [public_value()]} | {:error, public_error()}
  @spec list_history_page(binary(), public_map(), keyword() | public_map()) ::
          [public_value()] | {:ok, [public_value()]} | {:error, public_error()}
  @spec list_service_history(binary(), public_map(), keyword() | public_map()) ::
          [public_value()] | {:ok, [public_value()]} | {:error, public_error()}
  @spec mark_delivered(binary(), non_neg_integer(), public_map()) :: public_response()
  @spec mark_read(binary(), non_neg_integer(), public_map()) :: public_response()
  @spec message_event_visible?(binary(), binary(), public_map()) :: boolean()
  @spec refresh_sender_labels(binary(), [binary() | public_map()], public_map()) ::
          public_response()
  @spec remove_reaction(binary(), public_input(), public_map()) :: public_response()
  @spec search_for_service(public_input(), public_map(), keyword() | public_map()) ::
          [public_value()] | {:ok, [public_value()]} | {:error, public_error()}
  @spec search_page(public_input(), public_map(), keyword() | public_map()) ::
          [public_value()] | {:ok, [public_value()]} | {:error, public_error()}

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

  defdelegate mark_delivered(conversation_id, sequence, subject), to: DeliveryCursors
  defdelegate mark_read(conversation_id, sequence, subject), to: DeliveryCursors
  defdelegate list_delivery_cursors(conversation_id, subject), to: DeliveryCursors, as: :list
  defdelegate activity(conversation_id, subject, opts \\ []), to: Activity, as: :list
end
