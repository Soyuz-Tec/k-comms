defmodule CommsCore.Telephony do
  @moduledoc """
  Tenant-contained individual telephone calls, provisioning and durable call records.

  Provider events are accepted only through the configured verified integration;
  provider commands and cleanup are durable worker contributions.
  """
  alias CommsCore.Telephony.{
    CallView,
    CredentialRequest,
    Lifecycle,
    ProviderCommand,
    ProvisioningRequest,
    ProviderWebhookPort,
    VerifiedProviderEvent
  }

  @type response :: {:ok, map() | CallView.t()} | {:error, atom() | CommsCore.ValidationError.t()}
  @type provisioning_response ::
          {:ok, {map(), ProvisioningRequest.t() | nil}}
          | {:error, atom() | CommsCore.ValidationError.t()}

  @doc "Current-owner Phone provider setup; no carrier purchase or client credentials."
  @spec phone_provisioning_state(map()) :: response()
  defdelegate phone_provisioning_state(subject), to: CommsCore.Telephony.Provisioning, as: :state

  @spec inspect_phone_provisioning(map(), map()) :: provisioning_response()
  defdelegate inspect_phone_provisioning(attrs, subject),
    to: CommsCore.Telephony.Provisioning,
    as: :inspect

  @spec apply_phone_provisioning(String.t(), map(), map()) :: provisioning_response()
  defdelegate apply_phone_provisioning(id, attrs, subject),
    to: CommsCore.Telephony.Provisioning,
    as: :apply_configuration

  @spec reconcile_phone_provisioning(String.t(), map(), map()) :: provisioning_response()
  defdelegate reconcile_phone_provisioning(id, attrs, subject),
    to: CommsCore.Telephony.Provisioning,
    as: :reconcile

  @spec authorize_phone_provisioning_io(ProvisioningRequest.t(), :read | :effect, module()) ::
          :ok | {:error, atom()}
  defdelegate authorize_phone_provisioning_io(request, mode, caller),
    to: CommsCore.Telephony.Provisioning,
    as: :authorize_io

  @spec complete_phone_provisioning(
          ProvisioningRequest.t(),
          {:ok, map()} | {:error, atom()},
          map()
        ) ::
          response()
  defdelegate complete_phone_provisioning(request, result, subject),
    to: CommsCore.Telephony.Provisioning,
    as: :complete

  @spec rollback_phone_provisioning_hazard_count() :: non_neg_integer()
  defdelegate rollback_phone_provisioning_hazard_count(),
    to: CommsCore.Telephony.Provisioning,
    as: :rollback_hazard_count

  @doc false
  @spec release_tenant_fingerprint_fragment(module(), binary()) :: %{
          phone_provisioning_commands: [binary()]
        }
  defdelegate release_tenant_fingerprint_fragment(repo, tenant_id),
    to: CommsCore.Telephony.Provisioning

  @doc false
  @spec rollback_voicemail_hazard_count() :: non_neg_integer()
  defdelegate rollback_voicemail_hazard_count(), to: CommsCore.Telephony.Mailboxes
  @doc false
  @spec rollback_control_hazard_count() :: non_neg_integer()
  defdelegate rollback_control_hazard_count(), to: CommsCore.Telephony.Controls

  @doc false
  @spec release_tenant_fingerprint_fragment(module(), String.t()) :: %{atom() => [String.t()]}
  defdelegate release_tenant_fingerprint_fragment(repo, tenant_id),
    to: CommsCore.Telephony.ReleaseInventory,
    as: :tenant_fingerprint_fragment

  @spec config(map()) :: response()
  defdelegate config(subject), to: Lifecycle
  @spec admin_config(map()) :: response()
  defdelegate admin_config(subject), to: Lifecycle
  @spec provision(map(), map()) :: response()
  defdelegate provision(attrs, subject), to: Lifecycle
  @spec list_calls(map()) :: response()
  def list_calls(subject), do: Lifecycle.list_calls(subject, %{})
  @spec list_calls(map(), map()) :: response()
  defdelegate list_calls(subject, params), to: Lifecycle
  @spec get_call(String.t(), map()) :: response()
  defdelegate get_call(id, subject), to: Lifecycle

  @doc "Retain current exact ringing offer eligibility without claiming or answering a phone call."
  @spec native_wake_authority(binary(), map()) :: {:ok, DateTime.t()} | {:error, atom()}
  defdelegate native_wake_authority(id, subject), to: Lifecycle
  @spec native_wake_recipients(binary(), binary()) :: {:ok, [binary()]} | {:error, atom()}
  defdelegate native_wake_recipients(tenant, id), to: Lifecycle

  @spec start_outbound(map(), map()) ::
          {:ok, CallView.t(), :created | :replayed}
          | {:error, atom() | CommsCore.ValidationError.t()}
  defdelegate start_outbound(attrs, subject), to: Lifecycle

  @spec answer(String.t(), map(), (CredentialRequest.t() -> {:ok, map()} | {:error, atom()})) ::
          {:ok, CallView.t(), map()} | {:error, atom()}
  defdelegate answer(id, subject, issuer), to: Lifecycle

  @spec join(String.t(), map(), (CredentialRequest.t() -> {:ok, map()} | {:error, atom()})) ::
          {:ok, CallView.t(), map()} | {:error, atom()}
  defdelegate join(id, subject, issuer), to: Lifecycle
  @spec reject(String.t(), map()) :: response()
  defdelegate reject(id, subject), to: Lifecycle
  @spec end_call(String.t(), map()) :: response()
  defdelegate end_call(id, subject), to: Lifecycle

  @spec callback(map(), module()) ::
          {:ok, CallView.t() | nil, :applied | :duplicate | :ignored} | {:error, atom()}
  defdelegate callback(event, caller), to: Lifecycle

  @spec handle_webhook(binary(), binary()) ::
          {:ok, CallView.t() | nil, :applied | :duplicate | :ignored} | {:error, atom()}
  def handle_webhook(body, authorization) do
    with {:ok, %VerifiedProviderEvent{event: event, adapter: adapter}} <-
           ProviderWebhookPort.verify_webhook(body, authorization) do
      Lifecycle.callback(event, adapter)
    end
  end

  @spec claim_dispatch(String.t(), module()) ::
          {:ok, ProviderCommand.t() | atom() | {:not_ready, pos_integer()}} | {:error, atom()}
  defdelegate claim_dispatch(id, caller), to: Lifecycle

  @spec complete_dispatch(String.t(), :pending | {:ok, map()} | {:error, atom()}, module()) ::
          {:ok, atom()} | {:error, atom()}
  defdelegate complete_dispatch(id, result, caller), to: Lifecycle

  @spec expire(String.t(), module()) ::
          {:ok, atom() | {:not_due, pos_integer()}} | {:error, atom()}
  defdelegate expire(id, caller), to: Lifecycle

  @spec claim_cleanup(String.t(), module()) ::
          {:ok, ProviderCommand.t() | :already_clean | {:not_due, pos_integer()}}
          | {:error, atom()}
  defdelegate claim_cleanup(id, caller), to: Lifecycle

  @spec complete_cleanup(String.t(), :execute | :ok | {:error, atom()}, module()) ::
          :ok | {:ok, {:not_due, pos_integer()}} | {:error, atom()}
  defdelegate complete_cleanup(id, result, caller), to: Lifecycle

  @spec revoke_identity_access(CommsCore.Accounts.CallLifecycleCommand.t()) ::
          {:ok, CommsCore.Accounts.CallLifecycleReceipt.t()} | {:error, atom()}
  defdelegate revoke_identity_access(command), to: Lifecycle

  @spec revoke_tenant_media(CommsCore.Administration.CallLifecycleCommand.t()) ::
          {:ok, CommsCore.Administration.CallLifecycleReceipt.t()} | {:error, atom()}
  defdelegate revoke_tenant_media(command), to: Lifecycle
  @spec control_capabilities(map()) :: {:ok, map()} | {:error, atom()}
  defdelegate control_capabilities(subject), to: CommsCore.Telephony.Controls, as: :capabilities
  @spec list_controls(String.t(), map()) :: {:ok, map()} | {:error, atom()}
  defdelegate list_controls(id, subject), to: CommsCore.Telephony.Controls, as: :list

  @spec request_control(String.t(), map(), map()) ::
          {:ok, CommsCore.Telephony.ControlView.t()} | {:error, atom()}
  defdelegate request_control(id, attrs, subject), to: CommsCore.Telephony.Controls, as: :request

  @spec complete_browser_control(String.t(), String.t(), map(), map()) ::
          {:ok, CommsCore.Telephony.ControlView.t()} | {:error, atom()}
  defdelegate complete_browser_control(id, command_id, attrs, subject),
    to: CommsCore.Telephony.Controls,
    as: :complete_browser

  @spec claim_control(String.t(), module()) ::
          {:ok, CommsCore.Telephony.ControlRequest.t() | atom()} | {:error, atom()}
  defdelegate claim_control(id, caller), to: CommsCore.Telephony.Controls, as: :claim

  @spec bind_control(String.t(), map(), module()) ::
          {:ok, CommsCore.Telephony.ControlRequest.t()} | {:error, atom()}
  defdelegate bind_control(id, bindings, caller), to: CommsCore.Telephony.Controls, as: :bind

  @spec complete_control(
          String.t(),
          {:execute, boolean()} | {:ok, :submitted | map()} | {:error, atom()},
          module()
        ) ::
          {:ok, :complete | :snooze} | {:error, atom()}
  defdelegate complete_control(id, result, caller),
    to: CommsCore.Telephony.Controls,
    as: :complete

  @spec list_routes(map()) :: {:ok, map()} | {:error, atom()}
  defdelegate list_routes(subject), to: CommsCore.Telephony.Routing, as: :list

  @spec save_route(map(), map()) ::
          {:ok, map()} | {:error, atom() | CommsCore.ValidationError.t()}
  defdelegate save_route(attrs, subject), to: CommsCore.Telephony.Routing, as: :save

  @spec advance_route(String.t(), module()) ::
          {:ok,
           :complete | :expired | :unavailable | {:wait, pos_integer()} | {:offered, String.t()}}
          | {:error, atom()}
  defdelegate advance_route(id, caller), to: CommsCore.Telephony.Routing, as: :advance

  @spec route_provider_request(String.t(), module()) ::
          {:ok, CommsCore.Telephony.ControlRequest.t() | nil} | {:error, atom()}
  defdelegate route_provider_request(id, caller),
    to: CommsCore.Telephony.Routing,
    as: :provider_request

  @spec expire_route(String.t(), module()) :: {:ok, atom()} | {:error, atom()}
  defdelegate expire_route(id, caller), to: Lifecycle

  @spec control_provider_event(binary(), binary()) :: {:ok, atom()} | {:error, atom()}
  defdelegate control_provider_event(body, authorization),
    to: CommsCore.Telephony.Controls,
    as: :provider_event

  @spec mailbox_config(map()) :: {:ok, map()} | {:error, atom()}
  defdelegate mailbox_config(subject), to: CommsCore.Telephony.Mailboxes, as: :config

  @spec save_mailbox(map(), map()) ::
          {:ok, map()} | {:error, atom() | CommsCore.ValidationError.t()}
  defdelegate save_mailbox(attrs, subject), to: CommsCore.Telephony.Mailboxes, as: :save
  @spec list_voicemails(map(), map()) :: {:ok, map()} | {:error, atom()}
  defdelegate list_voicemails(subject, params), to: CommsCore.Telephony.Mailboxes, as: :list

  @spec voicemail_playback(String.t(), map()) ::
          {:ok, CommsCore.Telephony.VoicemailStoragePort.Contract.playback()} | {:error, atom()}
  defdelegate voicemail_playback(id, subject), to: CommsCore.Telephony.Mailboxes, as: :playback
  @spec delete_voicemail(String.t(), map()) :: {:ok, atom()} | {:error, atom()}
  defdelegate delete_voicemail(id, subject), to: CommsCore.Telephony.Mailboxes, as: :delete

  @spec claim_voicemail(String.t(), module()) ::
          {:ok, atom() | CommsCore.Telephony.VoicemailRequest.t()} | {:error, atom()}
  defdelegate claim_voicemail(id, caller), to: CommsCore.Telephony.Mailboxes, as: :claim

  @spec store_voicemail(
          String.t(),
          CommsCore.Telephony.VoicemailProviderPort.Contract.media(),
          module()
        ) :: {:ok, atom()} | {:error, atom()}
  defdelegate store_voicemail(id, media, caller), to: CommsCore.Telephony.Mailboxes, as: :store

  @spec complete_voicemail(String.t(), :deleted | {:ok, map()} | {:error, atom()}, module()) ::
          {:ok, atom()} | {:error, atom()}
  defdelegate complete_voicemail(id, result, caller),
    to: CommsCore.Telephony.Mailboxes,
    as: :complete

  @spec mark_voicemail_read(String.t(), map()) :: {:ok, map()} | {:error, atom()}
  defdelegate mark_voicemail_read(id, subject), to: CommsCore.Telephony.Mailboxes, as: :mark_read
  @spec purge_voicemail(String.t(), module()) :: {:ok, atom()} | {:error, atom()}
  defdelegate purge_voicemail(id, caller), to: CommsCore.Telephony.Mailboxes, as: :purge

  @spec cleanup_voicemail_source(String.t(), module()) :: {:ok, atom()} | {:error, atom()}
  defdelegate cleanup_voicemail_source(id, caller),
    to: CommsCore.Telephony.Mailboxes,
    as: :cleanup_source

  @spec enqueue_route_voicemail(String.t(), module()) :: {:ok, :voicemail} | {:error, atom()}
  defdelegate enqueue_route_voicemail(id, caller),
    to: CommsCore.Telephony.Controls,
    as: :queue_voicemail

  @spec prepare_governance_erasure(String.t(), :user | :conversation | :message, String.t()) ::
          {:ok, CommsCore.Telephony.VoicemailErasurePlan.t()} | {:error, atom()}
  defdelegate prepare_governance_erasure(tenant_id, target_type, target_id),
    to: CommsCore.Telephony.Mailboxes

  @spec governance_erasure_pending?(String.t(), :user | :conversation | :message, String.t()) ::
          {:ok, boolean()} | {:error, atom()}
  defdelegate governance_erasure_pending?(tenant_id, target_type, target_id),
    to: CommsCore.Telephony.Mailboxes

  @spec reconcile_control(String.t(), String.t(), map()) ::
          {:ok, CommsCore.Telephony.ControlView.t()} | {:error, atom()}
  defdelegate reconcile_control(id, command_id, subject),
    to: CommsCore.Telephony.Controls,
    as: :reconcile

  @doc "Content-free usage over currently retained owner records within an inclusive UTC range."
  @spec usage_projection(CommsCore.Telephony.UsageQuery.t(), map()) ::
          {:ok, CommsCore.Telephony.UsageProjection.t()}
          | {:error, :invalid_usage_query | :forbidden | :step_up_required}
  defdelegate usage_projection(query, subject), to: CommsCore.Telephony.UsageReports, as: :project

  @spec ivr_config(map()) ::
          {:ok, CommsCore.Telephony.IvrConfigView.t()} | {:error, atom()}
  defdelegate ivr_config(subject), to: CommsCore.Telephony.Ivr, as: :config

  @spec save_ivr(map(), map()) ::
          {:ok, CommsCore.Telephony.IvrMenuView.t()}
          | {:error, atom() | CommsCore.ValidationError.t()}
  defdelegate save_ivr(attrs, subject), to: CommsCore.Telephony.Ivr, as: :save
  @spec handle_ivr_webhook(binary(), binary()) :: {:ok, atom()} | {:error, atom()}
  defdelegate handle_ivr_webhook(body, authorization),
    to: CommsCore.Telephony.Ivr,
    as: :handle_webhook

  @spec advance_ivr(String.t(), module()) ::
          {:ok,
           atom() | {:wait, pos_integer()} | {:effect, CommsCore.Telephony.IvrEffectClaim.t()}}
          | {:error, atom()}
  defdelegate advance_ivr(id, caller), to: CommsCore.Telephony.Ivr, as: :advance

  @spec execute_ivr_claim(CommsCore.Telephony.IvrEffectClaim.t(), module()) ::
          {:ok,
           atom() | {:wait, pos_integer()} | {:effect, CommsCore.Telephony.IvrEffectClaim.t()}}
          | {:error, atom()}
  defdelegate execute_ivr_claim(claim, caller), to: CommsCore.Telephony.Ivr, as: :execute_claim
  @spec rollback_ivr_hazard_count() :: non_neg_integer()
  defdelegate rollback_ivr_hazard_count(), to: CommsCore.Telephony.Ivr, as: :rollback_hazard_count

  @spec agent_queue_state(map()) ::
          {:ok, CommsCore.Telephony.AgentQueueStateView.t()} | {:error, atom()}
  defdelegate agent_queue_state(subject), to: CommsCore.Telephony.ContactCenter, as: :agent_state

  @spec set_agent_queue_state(map(), map()) ::
          {:ok, CommsCore.Telephony.AgentQueueStateView.t()} | {:error, atom()}
  defdelegate set_agent_queue_state(attrs, subject),
    to: CommsCore.Telephony.ContactCenter,
    as: :set_agent_state

  @spec queue_supervisor_snapshot(map()) ::
          {:ok, CommsCore.Telephony.QueueSupervisorSnapshot.t()} | {:error, atom()}
  defdelegate queue_supervisor_snapshot(subject),
    to: CommsCore.Telephony.ContactCenter,
    as: :queue_snapshot

  @spec rollback_agent_state_hazard_count() :: non_neg_integer()
  defdelegate rollback_agent_state_hazard_count(),
    to: CommsCore.Telephony.ContactCenter,
    as: :rollback_hazard_count

  @spec erase_agent_queue_state(String.t(), String.t()) :: {:ok, non_neg_integer()}
  defdelegate erase_agent_queue_state(tenant_id, user_id),
    to: CommsCore.Telephony.ContactCenter,
    as: :erase_user!
end
