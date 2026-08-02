defmodule CommsCore.AudioCalls do
  @moduledoc """
  Stable Calls facade.

  Call lifecycle, admission, revocation, expiry, and persistence orchestration
  remain internal to the Calls context so released adapters continue to depend
  on one public facade.
  """

  @behaviour CommsCore.Accounts.CallLifecyclePort
  @behaviour CommsCore.Administration.CallLifecyclePort
  @behaviour CommsCore.Conversations.CallLifecyclePort

  alias CommsCore.AudioCalls.{Activity, Collaboration, Lifecycle}

  @doc false
  defdelegate release_tenant_fingerprint_fragment(repo, tenant_id), to: Lifecycle

  def start(conversation_id, subject), do: Lifecycle.start(conversation_id, subject)

  def start(conversation_id, subject, provider_cleanup_or_media_kind),
    do: Lifecycle.start(conversation_id, subject, provider_cleanup_or_media_kind)

  def start(conversation_id, subject, media_kind, provider_cleanup),
    do: Lifecycle.start(conversation_id, subject, media_kind, provider_cleanup)

  def start_with_kind(conversation_id, subject, media_kind),
    do: Lifecycle.start_with_kind(conversation_id, subject, media_kind)

  def start_with_kind(conversation_id, subject, media_kind, provider_cleanup),
    do: Lifecycle.start_with_kind(conversation_id, subject, media_kind, provider_cleanup)

  @doc """
  Atomically starts or replays a call and issues the starter credential.

  The call, expiry job, audit record, outbox events, admission, and credential
  issuance bookkeeping share one transaction. If the issuer fails or the
  caller loses authority while waiting for locks, a newly started call leaves
  no durable artifacts.
  """
  def start_with_join_authorized(
        conversation_id,
        subject,
        media_kind,
        provider_cleanup,
        issuer
      ),
      do:
        Lifecycle.start_with_join_authorized(
          conversation_id,
          subject,
          media_kind,
          provider_cleanup,
          issuer
        )

  @doc """
  Lists active or recent room sessions visible to an active human subject.

  Results are restricted to active conversation memberships and use a stable
  `started_at` plus id cursor. They model only facts owned by Calls: room
  modality, lifecycle status, timestamps, room-session duration, and whether
  the subject may currently end an active call.
  """
  @spec list_sessions(map(), map()) ::
          {:ok,
           %{
             calls: [CommsCore.AudioCalls.CallSessionView.t()],
             limit: pos_integer(),
             has_more: boolean(),
             next_cursor: String.t() | nil
           }}
          | {:error, :forbidden | :invalid_call_scope | :invalid_media_kind | :invalid_cursor}
  def list_sessions(subject, params \\ %{}), do: Lifecycle.list_sessions(subject, params)

  def get_active(conversation_id, subject),
    do: Lifecycle.get_active(conversation_id, subject)

  def get_active(conversation_id, subject, expected_kind),
    do: Lifecycle.get_active(conversation_id, subject, expected_kind)

  def authorize_join(conversation_id, call_id, subject),
    do: Lifecycle.authorize_join(conversation_id, call_id, subject)

  @doc """
  Executes credential issuance while holding the call row lock.

  End transitions use the same lock, so the issuer cannot run after a call has
  entered `ending`. The callback participates in this transaction, which also
  provides the extension point for atomically registering the issued provider
  participant identity. The returned credential is never persisted by this
  module.
  """
  def with_join_authorized(conversation_id, call_id, subject, issuer),
    do: Lifecycle.with_join_authorized(conversation_id, call_id, subject, issuer)

  def with_join_authorized(conversation_id, call_id, subject, expected_kind, issuer),
    do:
      Lifecycle.with_join_authorized(
        conversation_id,
        call_id,
        subject,
        expected_kind,
        issuer
      )

  @doc "Revokes active admissions for exact sessions and durably schedules provider eviction."
  def revoke_for_sessions(tenant_id, session_ids, reason),
    do: Lifecycle.revoke_for_sessions(tenant_id, session_ids, reason)

  @doc "Revokes active admissions issued to one device."
  def revoke_for_device(tenant_id, device_id, reason),
    do: Lifecycle.revoke_for_device(tenant_id, device_id, reason)

  @doc "Revokes every active admission for a tenant user."
  def revoke_for_user(tenant_id, user_id, reason),
    do: Lifecycle.revoke_for_user(tenant_id, user_id, reason)

  @doc "Revokes one member's active admission to an exact conversation."
  def revoke_for_membership(tenant_id, conversation_id, user_id, reason),
    do: Lifecycle.revoke_for_membership(tenant_id, conversation_id, user_id, reason)

  @doc "Revokes every active admission in an exact conversation."
  def revoke_for_conversation(tenant_id, conversation_id, reason),
    do: Lifecycle.revoke_for_conversation(tenant_id, conversation_id, reason)

  @doc "Revokes all active realtime-media admissions for a tenant."
  def revoke_for_tenant(tenant_id, reason),
    do: Lifecycle.revoke_for_tenant(tenant_id, reason)

  @doc "Revokes active admissions for exactly one media kind in a tenant."
  def revoke_for_tenant_kind(tenant_id, media_kind, reason),
    do: Lifecycle.revoke_for_tenant_kind(tenant_id, media_kind, reason)

  @doc "Revokes every active admission for one call after provider room termination."
  def revoke_for_call(tenant_id, call_id, reason),
    do: Lifecycle.revoke_for_call(tenant_id, call_id, reason)

  @impl CommsCore.Accounts.CallLifecyclePort
  def revoke_identity_access(command), do: Lifecycle.revoke_identity_access(command)

  @impl CommsCore.Administration.CallLifecyclePort
  def revoke_tenant_media(command), do: Lifecycle.revoke_tenant_media(command)

  @impl CommsCore.Conversations.CallLifecyclePort
  def revoke_conversation_access(command), do: Lifecycle.revoke_conversation_access(command)

  @doc false
  defdelegate claim_participant_eviction(participant_id, caller), to: Lifecycle

  @doc false
  defdelegate record_participant_eviction(participant_id, result, attempt_started_at, caller),
    to: Lifecycle

  @doc false
  defdelegate expire_call(call_id, caller, provider_cleanup), to: Lifecycle

  def authorize_end(conversation_id, call_id, attrs, subject),
    do: Lifecycle.authorize_end(conversation_id, call_id, attrs, subject)

  def can_end?(call, subject), do: Lifecycle.can_end?(call, subject)

  def end_call(conversation_id, call_id, attrs, subject),
    do: Lifecycle.end_call(conversation_id, call_id, attrs, subject)

  def end_call(conversation_id, call_id, attrs, subject, provider_cleanup),
    do: Lifecycle.end_call(conversation_id, call_id, attrs, subject, provider_cleanup)

  def end_call(conversation_id, call_id, attrs, subject, provider_cleanup, expected_kind),
    do:
      Lifecycle.end_call(
        conversation_id,
        call_id,
        attrs,
        subject,
        provider_cleanup,
        expected_kind
      )

  defdelegate activity(conversation_id, subject, opts \\ []), to: Activity, as: :list
  defdelegate list_participants(conversation_id, call_id, subject), to: Collaboration
  defdelegate authorize_participant(conversation_id, call_id, subject), to: Collaboration
  defdelegate set_hand(conversation_id, call_id, raised, subject), to: Collaboration

  defdelegate moderation_target(conversation_id, call_id, provider_identity, subject),
    to: Collaboration

  defdelegate remove_participant(conversation_id, call_id, provider_identity, subject),
    to: Collaboration

  defdelegate record_participant_mute(target, conversation_id, subject),
    to: Collaboration,
    as: :record_mute
end
