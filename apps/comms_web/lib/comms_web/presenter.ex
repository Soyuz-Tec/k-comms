defmodule CommsWeb.Presenter do
  @moduledoc """
  Stable presentation facade for HTTP and realtime adapters.

  Feature-owned presenter modules keep response construction cohesive while
  this facade preserves every existing caller and serialized contract.
  """

  alias CommsWeb.Presenters.{
    Administration,
    Calls,
    ConversationContent,
    Conversations,
    Governance,
    Identity
  }

  defdelegate tenant(value), to: Administration
  defdelegate tenant_settings(value), to: Administration
  defdelegate tenant_usage(value), to: Administration
  defdelegate invitation(value), to: Administration
  defdelegate audit_event(value), to: Administration

  defdelegate user(value), to: Identity
  defdelegate identity_user(value), to: Identity
  defdelegate guest_identity(value), to: Identity
  defdelegate admin_user(value), to: Identity
  defdelegate directory_person(value), to: Identity
  defdelegate retained_sender_label(value), to: Identity
  defdelegate device(value), to: Identity
  defdelegate session(value), to: Identity

  defdelegate conversation(value), to: Conversations
  defdelegate public_channel(value), to: Conversations
  defdelegate membership(value), to: Conversations
  defdelegate guest_membership(value), to: Conversations
  defdelegate guest_link(value), to: Conversations
  defdelegate guest_admission(value), to: Conversations
  defdelegate guest_preview(value), to: Conversations
  defdelegate instant_room(value), to: Conversations
  defdelegate instant_room_preview(value), to: Conversations
  defdelegate guest_capabilities(value), to: Conversations

  defdelegate audio_call(value), to: Calls
  defdelegate call_session(value), to: Calls

  defdelegate moderation_case(value), to: Governance
  defdelegate moderation_action(value), to: Governance
  defdelegate retention_policy(value), to: Governance
  defdelegate legal_hold(value), to: Governance
  defdelegate deletion_request(value), to: Governance

  defdelegate message(value), to: ConversationContent
  defdelegate attachment(value), to: ConversationContent
  defdelegate file(value), to: ConversationContent
  defdelegate whiteboard_operation(value), to: ConversationContent
  defdelegate whiteboard_snapshot(value), to: ConversationContent
end
