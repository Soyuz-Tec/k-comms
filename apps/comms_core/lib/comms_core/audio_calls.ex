defmodule CommsCore.AudioCalls do
  @moduledoc """
  Stable Calls facade.

  Call lifecycle, admission, revocation, expiry, and persistence orchestration
  remain internal to the Calls context so released adapters continue to depend
  on one public facade.
  """

  @behaviour CommsCore.Conversations.CallLifecyclePort

  alias CommsCore.AudioCalls.{Activity, Artifacts, Collaboration, Lifecycle, Meetings}

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
          CommsCore.AudioCalls.UsageQuery.t()
          | CommsCore.AudioCalls.UsageProjection.t()
          | CommsCore.AudioCalls.ActivityView.t()
          | CommsCore.AudioCalls.ArtifactErasurePlan.t()
          | CommsCore.AudioCalls.ArtifactView.t()
          | CommsCore.AudioCalls.CallParticipantView.t()
          | CommsCore.AudioCalls.CallSessionView.t()
          | CommsCore.AudioCalls.CallView.t()
          | CommsCore.AudioCalls.CredentialRequest.t()
          | CommsCore.AudioCalls.EvictionClaim.t()
          | CommsCore.AudioCalls.EvictionProgress.t()
          | CommsCore.AudioCalls.ModerationTarget.t()
          | CommsCore.AudioCalls.MeetingErasurePlan.t()
          | CommsCore.AudioCalls.MeetingView.t()
          | CommsCore.AudioCalls.ProviderCall.t()
          | CommsCore.AudioCalls.CalendarSync.AuthorizationReceipt.t()
          | CommsCore.AudioCalls.CalendarSync.CallbackCommand.t()
          | CommsCore.AudioCalls.CalendarSync.ConnectionView.t()
          | CommsCore.AudioCalls.CalendarSync.ExportView.t()
          | CommsCore.AudioCalls.CalendarSync.ErasurePlan.t()
          | CommsCore.AudioCalls.CalendarSync.IdentityFenceCommand.t()
          | CommsCore.AudioCalls.CalendarSync.IdentityFenceReceipt.t()

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

  @spec activity(binary(), public_map(), keyword() | public_map()) ::
          [public_value()] | {:ok, [public_value()]} | {:error, public_error()}
  @spec authorize_participant(binary(), binary(), public_map()) ::
          :ok | {:ok, public_value()} | {:error, public_error()}
  @spec claim_participant_eviction(binary(), module()) :: public_response()
  @spec end_call(binary(), binary(), public_map(), public_map(), function(), public_input()) ::
          public_response()
  @spec expire_call(binary(), module(), function()) :: public_response()
  @spec get_active(binary(), public_map()) :: public_response()
  @spec get_active(binary(), public_map(), public_input()) :: public_response()
  @spec list_participants(binary(), binary(), public_map()) ::
          [public_value()] | {:ok, [public_value()]} | {:error, public_error()}
  @spec moderation_target(binary(), binary(), binary(), public_map()) :: public_response()
  @spec record_participant_eviction(
          binary(),
          public_map(),
          DateTime.t() | NaiveDateTime.t(),
          module()
        ) :: public_response()
  @spec record_participant_mute(public_map(), binary(), public_map()) :: public_response()
  @spec remove_participant(binary(), binary(), binary(), public_map()) :: public_response()
  @spec set_hand(binary(), binary(), boolean(), public_map()) :: public_response()
  @spec start_with_join_authorized(
          binary(),
          public_map(),
          atom() | binary(),
          function(),
          function()
        ) :: public_response()
  @spec with_join_authorized(binary(), binary(), public_map(), public_input(), function()) ::
          public_response()

  @spec list_calendar_connections(public_map()) :: public_response()
  defdelegate list_calendar_connections(subject),
    to: CommsCore.AudioCalls.CalendarSync.Connections,
    as: :list

  @spec begin_calendar_authorization(:google | :microsoft, public_map(), public_map()) ::
          public_response()
  defdelegate begin_calendar_authorization(provider, attrs, subject),
    to: CommsCore.AudioCalls.CalendarSync.Connections,
    as: :begin

  @spec complete_calendar_authorization(CommsCore.AudioCalls.CalendarSync.CallbackCommand.t()) ::
          public_response()
  defdelegate complete_calendar_authorization(command),
    to: CommsCore.AudioCalls.CalendarSync.Connections,
    as: :callback

  @spec unlink_calendar_connection(binary(), public_map(), public_map()) :: public_response()
  defdelegate unlink_calendar_connection(id, attrs, subject),
    to: CommsCore.AudioCalls.CalendarSync.Connections,
    as: :unlink

  @spec list_calendar_exports(public_map(), public_map()) :: public_response()
  defdelegate list_calendar_exports(subject, attrs),
    to: CommsCore.AudioCalls.CalendarSync.Exports,
    as: :list

  @spec create_calendar_export(public_map(), public_map()) :: public_response()
  defdelegate create_calendar_export(attrs, subject),
    to: CommsCore.AudioCalls.CalendarSync.Exports,
    as: :create

  @spec resolve_calendar_export(binary(), public_map(), public_map()) :: public_response()
  defdelegate resolve_calendar_export(id, attrs, subject),
    to: CommsCore.AudioCalls.CalendarSync.Exports,
    as: :resolve

  @spec perform_calendar_command(binary(), pos_integer(), module()) :: public_response()
  defdelegate perform_calendar_command(id, generation, caller),
    to: CommsCore.AudioCalls.CalendarSync.Effects,
    as: :perform

  @spec reconcile_calendar_commands(pos_integer(), module()) :: public_response()
  defdelegate reconcile_calendar_commands(limit, caller),
    to: CommsCore.AudioCalls.CalendarSync.Effects,
    as: :reconcile

  @spec fence_calendar_tenant(binary()) :: {:ok, non_neg_integer()} | {:error, public_error()}
  defdelegate fence_calendar_tenant(tenant),
    to: CommsCore.AudioCalls.CalendarSync.IdentityFences,
    as: :tenant

  @spec fence_calendar_identity(CommsCore.AudioCalls.CalendarSync.IdentityFenceCommand.t()) ::
          public_response()
  defdelegate fence_calendar_identity(command),
    to: CommsCore.AudioCalls.CalendarSync.IdentityFences,
    as: :apply

  @spec prepare_calendar_governance_erasure(binary(), :user | :conversation | :message, binary()) ::
          public_response()
  defdelegate prepare_calendar_governance_erasure(tenant, type, target),
    to: CommsCore.AudioCalls.CalendarSync.Erasure,
    as: :prepare

  @spec calendar_governance_erasure_pending?(binary(), :user | :conversation | :message, binary()) ::
          {:ok, boolean()} | {:error, public_error()}
  defdelegate calendar_governance_erasure_pending?(tenant, type, target),
    to: CommsCore.AudioCalls.CalendarSync.Erasure,
    as: :pending?

  @doc false
  def release_tenant_fingerprint_fragment(repo, tenant_id),
    do:
      Map.merge(
        Lifecycle.release_tenant_fingerprint_fragment(repo, tenant_id),
        CommsCore.AudioCalls.CalendarSync.ReleaseInventory.tenant_fingerprint_fragment(
          repo,
          tenant_id
        )
      )

  @spec rollback_calendar_hazard_count() :: non_neg_integer()
  defdelegate rollback_calendar_hazard_count(),
    to: CommsCore.AudioCalls.CalendarSync.ReleaseInventory,
    as: :hazard_count

  @spec rollback_calendar_erasure_hazard_count() :: non_neg_integer()
  defdelegate rollback_calendar_erasure_hazard_count(),
    to: CommsCore.AudioCalls.CalendarSync.ReleaseInventory,
    as: :erasure_hazard_count

  @spec schedule_meeting(binary(), public_map(), public_map()) ::
          {:ok, CommsCore.AudioCalls.MeetingView.t()} | {:error, public_error()}
  defdelegate schedule_meeting(conversation_id, attrs, subject), to: Meetings, as: :create

  @spec update_meeting(binary(), public_map(), public_map()) ::
          {:ok, CommsCore.AudioCalls.MeetingView.t()} | {:error, public_error()}
  defdelegate update_meeting(id, attrs, subject), to: Meetings, as: :update

  @spec cancel_meeting(binary(), public_map(), public_map()) ::
          {:ok, CommsCore.AudioCalls.MeetingView.t()} | {:error, public_error()}
  defdelegate cancel_meeting(id, attrs, subject), to: Meetings, as: :cancel

  @spec get_meeting(binary(), public_map()) ::
          {:ok, CommsCore.AudioCalls.MeetingView.t()} | {:error, public_error()}
  defdelegate get_meeting(id, subject), to: Meetings, as: :get

  @spec list_meetings(public_map(), public_map()) ::
          {:ok, %{meetings: [CommsCore.AudioCalls.MeetingView.t()], truncated: boolean()}}
          | {:error, public_error()}
  defdelegate list_meetings(subject, params), to: Meetings, as: :list

  @spec search_meetings(public_map(), public_map()) ::
          {:ok, %{meetings: [CommsCore.AudioCalls.MeetingView.t()], truncated: boolean()}}
          | {:error, public_error()}
  defdelegate search_meetings(subject, params), to: Meetings, as: :search

  @spec meeting_calendar(binary(), public_map()) :: {:ok, String.t()} | {:error, public_error()}
  defdelegate meeting_calendar(id, subject), to: Meetings, as: :calendar

  @spec start_meeting(binary(), binary(), public_map(), :audio | :video, function(), function()) ::
          {:ok,
           %{
             call: CommsCore.AudioCalls.CallView.t(),
             status: :created | :existing,
             credential: public_map()
           }}
          | {:error, public_error()}
  defdelegate start_meeting(id, occurrence_id, subject, kind, cleanup, issuer),
    to: Meetings,
    as: :start

  @spec deliver_meeting_reminder(binary(), pos_integer(), module()) ::
          {:ok, :ignored | :already_delivered | :delivered} | {:error, public_error()}
  defdelegate deliver_meeting_reminder(occurrence_id, version, caller),
    to: Meetings,
    as: :deliver_reminder

  @doc false
  @spec rollback_artifact_hazard_count() :: non_neg_integer()
  defdelegate rollback_artifact_hazard_count(), to: Artifacts, as: :rollback_hazard_count

  @doc false
  @spec rollback_meeting_hazard_count() :: non_neg_integer()
  defdelegate rollback_meeting_hazard_count(), to: Meetings, as: :rollback_hazard_count

  @doc false
  @spec prepare_meeting_governance_erasure(binary(), :user | :conversation | :message, binary()) ::
          {:ok, CommsCore.AudioCalls.MeetingErasurePlan.t()} | {:error, public_error()}
  defdelegate prepare_meeting_governance_erasure(tenant_id, target_type, target_id),
    to: Meetings,
    as: :prepare_governance_erasure

  @doc false
  @spec meeting_governance_erasure_pending?(binary(), :user | :conversation | :message, binary()) ::
          {:ok, boolean()} | {:error, public_error()}
  defdelegate meeting_governance_erasure_pending?(tenant_id, target_type, target_id),
    to: Meetings,
    as: :governance_erasure_pending?

  @spec list_artifacts(binary(), binary(), public_map()) ::
          {:ok, %{artifacts: [CommsCore.AudioCalls.ArtifactView.t()], capabilities: public_map()}}
          | {:error, public_error()}
  defdelegate list_artifacts(conversation_id, call_id, subject), to: Artifacts, as: :list

  @spec search_artifacts(public_map(), public_map()) ::
          {:ok, [CommsCore.AudioCalls.ArtifactView.t()]} | {:error, public_error()}
  defdelegate search_artifacts(subject, params), to: Artifacts, as: :search

  @spec request_artifact(binary(), binary(), public_map(), public_map()) ::
          {:ok, CommsCore.AudioCalls.ArtifactView.t()} | {:error, public_error()}
  defdelegate request_artifact(conversation_id, call_id, attrs, subject),
    to: Artifacts,
    as: :request

  @spec consent_artifact(binary(), binary(), binary(), boolean(), public_map()) ::
          {:ok, CommsCore.AudioCalls.ArtifactView.t()} | {:error, public_error()}
  defdelegate consent_artifact(conversation_id, call_id, id, accepted, subject),
    to: Artifacts,
    as: :consent

  @spec start_artifact(binary(), binary(), binary(), public_map()) ::
          {:ok, CommsCore.AudioCalls.ArtifactView.t()} | {:error, public_error()}
  defdelegate start_artifact(conversation_id, call_id, id, subject), to: Artifacts, as: :start

  @spec stop_artifact(binary(), binary(), binary(), public_map()) ::
          {:ok, CommsCore.AudioCalls.ArtifactView.t()} | {:error, public_error()}
  defdelegate stop_artifact(conversation_id, call_id, id, subject), to: Artifacts, as: :stop

  @spec delete_artifact(binary(), binary(), binary(), public_map()) ::
          {:ok, CommsCore.AudioCalls.ArtifactView.t()} | {:error, public_error()}
  defdelegate delete_artifact(conversation_id, call_id, id, subject), to: Artifacts, as: :delete

  @spec artifact_playback(binary(), binary(), binary(), public_map()) ::
          {:ok, %{artifact: CommsCore.AudioCalls.ArtifactView.t(), download: public_map()}}
          | {:error, public_error()}
  defdelegate artifact_playback(conversation_id, call_id, id, subject),
    to: Artifacts,
    as: :playback

  @spec artifact_transcript(binary(), binary(), binary(), public_map()) ::
          {:ok,
           %{
             artifact: CommsCore.AudioCalls.ArtifactView.t(),
             segments: [CommsCore.AudioCalls.ArtifactTranscriptSegment.t()]
           }}
          | {:error, public_error()}
  defdelegate artifact_transcript(conversation_id, call_id, id, subject),
    to: Artifacts,
    as: :transcript

  @spec handle_artifact_callback(binary(), binary()) :: public_response()
  defdelegate handle_artifact_callback(body, authorization), to: Artifacts, as: :handle_callback

  @spec process_artifact(binary(), module()) :: public_response()
  defdelegate process_artifact(id, caller), to: Artifacts, as: :process

  @spec reconcile_artifacts(module()) :: public_response()
  defdelegate reconcile_artifacts(caller), to: Artifacts, as: :reconcile

  @spec prepare_governance_erasure(binary(), atom(), binary()) ::
          {:ok, CommsCore.AudioCalls.ArtifactErasurePlan.t()} | {:error, public_error()}
  defdelegate prepare_governance_erasure(tenant_id, subject_type, subject_id), to: Artifacts

  @spec governance_erasure_pending?(binary(), atom(), binary()) ::
          {:ok, boolean()} | {:error, public_error()}
  defdelegate governance_erasure_pending?(tenant_id, subject_type, subject_id), to: Artifacts

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

  @doc false
  def revoke_identity_access(command), do: Lifecycle.revoke_identity_access(command)

  @doc false
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

  @doc "Content-free usage over currently retained owner records within an inclusive UTC range."
  @spec usage_projection(CommsCore.AudioCalls.UsageQuery.t(), map()) ::
          {:ok, CommsCore.AudioCalls.UsageProjection.t()}
          | {:error, :invalid_usage_query | :forbidden | :step_up_required}
  defdelegate usage_projection(query, subject),
    to: CommsCore.AudioCalls.UsageReports,
    as: :project
end
