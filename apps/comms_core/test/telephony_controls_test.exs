defmodule CommsCore.TelephonyControlsTest.Provider do
  @behaviour CommsCore.Telephony.ProviderControlPort.Contract
  def capabilities(),
    do:
      Map.new(
        [
          :dtmf,
          :hold,
          :resume,
          :blind_transfer,
          :consult_transfer,
          :complete_transfer,
          :cancel_transfer,
          :queues,
          :shared_lines
        ],
        &{&1, %{supported: true, reason: nil}}
      )

  def authorize_destination("+" <> _), do: :ok
  def authorize_destination(_), do: {:error, :telephony_destination_forbidden}
  def verify_event(_, _), do: {:error, :invalid_provider_webhook}
  def cleanup_call(_), do: {:error, :telephony_provider_unavailable}
  def bound_call_status(_), do: {:error, :telephony_provider_unavailable}

  def execute_control(request) do
    send(self(), {:control_effect, request.action})
    {:ok, :submitted}
  end
end

defmodule CommsCore.TelephonyControlsTest do
  use CommsCore.DataCase, async: false
  @moduletag :integration
  @moduletag :call
  alias CommsCore.{Accounts, Telephony}
  alias CommsCore.Telephony.{Call, ControlCommand, ControlRequest}
  alias CommsTestSupport.Fixtures
  alias CommsWorkers.TelephonyControlWorker

  setup do
    previous = Application.fetch_env(:comms_core, :telephony_control_adapter)
    previous_key = Application.fetch_env(:comms_core, :telephony_control_fingerprint_key)

    Application.put_env(
      :comms_core,
      :telephony_control_adapter,
      CommsCore.TelephonyControlsTest.Provider
    )

    Application.put_env(
      :comms_core,
      :telephony_control_fingerprint_key,
      String.duplicate("k", 32)
    )

    on_exit(fn ->
      restore(:telephony_control_adapter, previous)
      restore(:telephony_control_fingerprint_key, previous_key)
    end)

    :ok
  end

  test "DTMF is a single-use instruction; replay never sends again and changed payload conflicts" do
    {account, subject, call} = connected()
    input = %{action: "dtmf", digit: "5", idempotency_key: "single-tone"}
    assert {:ok, first} = Telephony.request_control(call.id, input, subject)
    assert first.dispatch and first.status == :dispatching
    assert {:ok, replay} = Telephony.request_control(call.id, input, subject)
    refute replay.dispatch
    assert replay.id == first.id

    assert {:error, :idempotency_conflict} =
             Telephony.request_control(call.id, %{input | digit: "6"}, subject)

    assert {:ok, receipt} =
             Telephony.complete_browser_control(
               call.id,
               first.id,
               %{status: "submitted"},
               subject
             )

    assert receipt.status == :submitted
    stored = Repo.get!(ControlCommand, first.id)
    assert is_nil(stored.destination)
    refute stored.payload_hash == Base.encode16(:crypto.hash(:sha256, "dtmf:5"), case: :lower)
    assert Repo.aggregate(ControlCommand, :count) == 1
    assert account.user.id == Repo.get!(Call, call.id).user_id
  end

  test "competing device, revoked session, unconnected call, foreign tenant and malformed digits cannot dispatch" do
    {account, subject, call} = connected()
    second = second_device(account)

    assert {:error, :answered_elsewhere} =
             Telephony.request_control(
               call.id,
               %{action: "dtmf", digit: "1", idempotency_key: "second"},
               second
             )

    foreign = Fixtures.account_fixture()

    assert {:error, :not_found} =
             Telephony.request_control(
               call.id,
               %{action: "hold", idempotency_key: "foreign"},
               Fixtures.subject(foreign)
             )

    assert {:error, :invalid_telephony_command} =
             Telephony.request_control(
               call.id,
               %{action: "dtmf", digit: "12", idempotency_key: "long"},
               subject
             )

    assert {:ok, _} = Telephony.end_call(call.id, subject)

    assert {:error, :invalid_call_action} =
             Telephony.request_control(
               call.id,
               %{action: "hold", idempotency_key: "ended"},
               subject
             )

    assert Repo.aggregate(ControlCommand, :count) == 0
  end

  test "uncertain REFER claims remain unknown and are never reissued after restart" do
    {_account, subject, call} = connected()

    input = %{
      action: "blind_transfer",
      destination: "+14155550123",
      idempotency_key: "once-refer"
    }

    assert {:ok, receipt} = Telephony.request_control(call.id, input, subject)

    assert {:ok, %ControlRequest{reconcile: false}} =
             Telephony.claim_control(receipt.id, TelephonyControlWorker)

    assert {:ok, :already_claimed} = Telephony.claim_control(receipt.id, TelephonyControlWorker)
    assert Repo.get!(ControlCommand, receipt.id).status == :unknown
    assert {:ok, replay} = Telephony.request_control(call.id, input, subject)
    assert replay.status == :unknown

    assert {:error, :telephony_control_conflict} =
             Telephony.request_control(
               call.id,
               %{action: "hold", idempotency_key: "conflicting"},
               subject
             )
  end

  test "PBX hold binding persists before effects and recovery reconciles exact saved IDs" do
    {_account, subject, call} = connected()

    assert {:ok, receipt} =
             Telephony.request_control(
               call.id,
               %{action: "hold", idempotency_key: "hold-once"},
               subject
             )

    assert {:error, :forbidden} = Telephony.claim_control(receipt.id, __MODULE__)

    assert {:ok, %ControlRequest{reconcile: false}} =
             Telephony.claim_control(receipt.id, TelephonyControlWorker)

    bindings = %{
      "external" => "external",
      "app" => "app",
      "mixing" => "mixing",
      "holding" => "holding",
      "consult" => "consult",
      "recording" => "recording"
    }

    assert {:ok, %ControlRequest{pbx_state: ^bindings}} =
             Telephony.bind_control(receipt.id, bindings, TelephonyControlWorker)

    assert {:ok, %ControlRequest{reconcile: true, pbx_state: ^bindings}} =
             Telephony.claim_control(receipt.id, TelephonyControlWorker)

    assert {:error, :telephony_pbx_binding_invalid} =
             Telephony.bind_control(
               receipt.id,
               %{bindings | "external" => "replacement"},
               TelephonyControlWorker
             )

    assert {:ok, :complete} =
             Telephony.complete_control(
               receipt.id,
               {:ok, %{control_state: "held", pbx_state: bindings}},
               TelephonyControlWorker
             )

    assert Repo.get!(Call, call.id).control_state == "held"
  end

  test "only the owning device can compensate one claimed unknown consult using persisted bindings" do
    {account, subject, call} = connected()

    input = %{
      action: "consult_transfer",
      destination: "+14155550123",
      idempotency_key: "uncertain-consult"
    }

    assert {:ok, receipt} = Telephony.request_control(call.id, input, subject)
    cancel = %{action: "cancel_transfer", idempotency_key: "compensate-consult"}
    assert {:error, :invalid_call_action} = Telephony.request_control(call.id, cancel, subject)
    assert {:ok, %ControlRequest{}} = Telephony.claim_control(receipt.id, TelephonyControlWorker)

    bindings = %{
      "external" => "external",
      "app" => "app",
      "mixing" => "mixing",
      "holding" => "holding",
      "consult" => "consult",
      "recording" => "recording"
    }

    assert {:ok, _} = Telephony.bind_control(receipt.id, bindings, TelephonyControlWorker)

    assert {:ok, :complete} =
             Telephony.complete_control(
               receipt.id,
               {:error, :telephony_outcome_unknown},
               TelephonyControlWorker
             )

    assert {:error, :answered_elsewhere} =
             Telephony.request_control(call.id, cancel, second_device(account))

    assert {:error, :not_found} =
             Telephony.request_control(
               call.id,
               cancel,
               Fixtures.subject(Fixtures.account_fixture())
             )

    assert {:ok, recovery} = Telephony.request_control(call.id, cancel, subject)
    assert recovery.status == :pending
    previous = Repo.get!(ControlCommand, receipt.id)
    assert previous.status == :failed and previous.failure_reason == "superseded_by_cancel"
    assert {:ok, :already_complete} = Telephony.claim_control(receipt.id, TelephonyControlWorker)
    assert {:ok, repeated} = Telephony.request_control(call.id, cancel, subject)
    assert repeated.id == recovery.id

    assert {:error, :telephony_control_conflict} =
             Telephony.request_control(
               call.id,
               %{action: "hold", idempotency_key: "blocked-during-cancel"},
               subject
             )

    assert {:ok, %ControlRequest{action: :cancel_transfer, pbx_state: ^bindings}} =
             Telephony.claim_control(recovery.id, TelephonyControlWorker)

    assert {:ok, :complete} =
             Telephony.complete_control(
               recovery.id,
               {:ok, %{control_state: "connected", pbx_state: bindings}},
               TelephonyControlWorker
             )

    assert {:ok, _} =
             Telephony.request_control(
               call.id,
               %{action: "hold", idempotency_key: "after-confirmed-cancel"},
               subject
             )
  end

  test "unknown hold is never superseded by consultation cancellation" do
    {_account, subject, call} = connected()

    assert {:ok, receipt} =
             Telephony.request_control(
               call.id,
               %{action: "hold", idempotency_key: "uncertain-hold"},
               subject
             )

    assert {:ok, _} = Telephony.claim_control(receipt.id, TelephonyControlWorker)

    assert {:ok, _} =
             Telephony.complete_control(
               receipt.id,
               {:error, :telephony_outcome_unknown},
               TelephonyControlWorker
             )

    assert {:error, :invalid_call_action} =
             Telephony.request_control(
               call.id,
               %{action: "cancel_transfer", idempotency_key: "cannot-supersede-hold"},
               subject
             )

    assert Repo.get!(ControlCommand, receipt.id).status == :unknown
  end

  test "session revocation after claim and bind prevents the final provider effect" do
    {account, subject, call} = connected()

    assert {:ok, receipt} =
             Telephony.request_control(
               call.id,
               %{action: "hold", idempotency_key: "revoked-after-bind"},
               subject
             )

    assert {:ok, _} = Telephony.claim_control(receipt.id, TelephonyControlWorker)

    bindings = %{
      "external" => "external",
      "app" => "app",
      "mixing" => "mixing",
      "holding" => "holding",
      "consult" => "consult",
      "recording" => "recording"
    }

    assert {:ok, _} = Telephony.bind_control(receipt.id, bindings, TelephonyControlWorker)
    assert :ok = Accounts.revoke_session(subject.session_id, account.user.id)

    assert {:ok, :complete} =
             Telephony.complete_control(receipt.id, {:execute, false}, TelephonyControlWorker)

    refute_received {:control_effect, _}
    assert Repo.get!(ControlCommand, receipt.id).failure_reason == "access_revoked"
  end

  test "ending a call after bind prevents the final provider effect" do
    {_account, subject, call} = connected()

    assert {:ok, receipt} =
             Telephony.request_control(
               call.id,
               %{action: "hold", idempotency_key: "ended-after-bind"},
               subject
             )

    assert {:ok, _} = Telephony.claim_control(receipt.id, TelephonyControlWorker)

    bindings = %{
      "external" => "external",
      "app" => "app",
      "mixing" => "mixing",
      "holding" => "holding",
      "consult" => "consult",
      "recording" => "recording"
    }

    assert {:ok, _} = Telephony.bind_control(receipt.id, bindings, TelephonyControlWorker)
    assert {:ok, _} = Telephony.end_call(call.id, subject)

    assert {:ok, :complete} =
             Telephony.complete_control(receipt.id, {:execute, false}, TelephonyControlWorker)

    refute_received {:control_effect, _}
    assert Repo.get!(ControlCommand, receipt.id).failure_reason == "call_unavailable"
  end

  test "a live authorized dispatch executes the provider exactly once" do
    bindings = %{
      "external" => "external",
      "app" => "app",
      "mixing" => "mixing",
      "holding" => "holding",
      "consult" => "consult",
      "recording" => "recording"
    }

    {_account, live_subject, live_call} = connected()

    assert {:ok, active} =
             Telephony.request_control(
               live_call.id,
               %{action: "hold", idempotency_key: "authorized-effect"},
               live_subject
             )

    assert {:ok, _} = Telephony.claim_control(active.id, TelephonyControlWorker)
    assert {:ok, _} = Telephony.bind_control(active.id, bindings, TelephonyControlWorker)

    assert {:ok, :complete} =
             Telephony.complete_control(active.id, {:execute, false}, TelephonyControlWorker)

    assert_received {:control_effect, :hold}

    assert {:ok, :complete} =
             Telephony.complete_control(active.id, {:execute, false}, TelephonyControlWorker)

    refute_received {:control_effect, _}
  end

  test "a command expiring after bind cannot start a delayed forward effect" do
    {_account, subject, call} = connected()

    assert {:ok, receipt} =
             Telephony.request_control(
               call.id,
               %{
                 action: "consult_transfer",
                 destination: "+14155550123",
                 idempotency_key: "expires-before-effect"
               },
               subject
             )

    assert {:ok, _} = Telephony.claim_control(receipt.id, TelephonyControlWorker)

    bindings = %{
      "external" => "external",
      "app" => "app",
      "mixing" => "mixing",
      "holding" => "holding",
      "consult" => "consult",
      "recording" => "recording"
    }

    assert {:ok, _} = Telephony.bind_control(receipt.id, bindings, TelephonyControlWorker)

    Repo.get!(ControlCommand, receipt.id)
    |> ControlCommand.changeset(%{expires_at: DateTime.add(DateTime.utc_now(), -1, :second)})
    |> Repo.update!()

    assert {:ok, :complete} =
             Telephony.complete_control(receipt.id, {:execute, false}, TelephonyControlWorker)

    refute_received {:control_effect, _}
    assert Repo.get!(ControlCommand, receipt.id).failure_reason == "control_authorization_expired"
    assert {:ok, _} = Telephony.reconcile_control(call.id, receipt.id, subject)

    assert DateTime.compare(Repo.get!(ControlCommand, receipt.id).expires_at, DateTime.utc_now()) ==
             :gt
  end

  test "expired SDK acknowledgment is unknown and unavailable provider does not create command" do
    {_account, subject, call} = connected()

    assert {:ok, receipt} =
             Telephony.request_control(
               call.id,
               %{action: "dtmf", digit: "#", idempotency_key: "expired"},
               subject
             )

    command = Repo.get!(ControlCommand, receipt.id)

    command
    |> ControlCommand.changeset(%{expires_at: DateTime.add(DateTime.utc_now(), -1, :second)})
    |> Repo.update!()

    assert {:ok, %{status: :unknown}} =
             Telephony.complete_browser_control(
               call.id,
               receipt.id,
               %{status: "submitted"},
               subject
             )

    Application.delete_env(:comms_core, :telephony_control_adapter)

    assert {:error, :telephony_control_unsupported} =
             Telephony.request_control(
               call.id,
               %{action: "hold", idempotency_key: "disabled"},
               subject
             )
  end

  test "rollback hazards distinguish advanced unresolved work from first-milestone SIP calls and terminal history" do
    {_account, subject, call} = connected()
    assert Telephony.rollback_control_hazard_count() == 0

    assert {:ok, control} =
             Telephony.request_control(
               call.id,
               %{action: "hold", idempotency_key: "rollback-hold"},
               subject
             )

    assert Telephony.rollback_control_hazard_count() == 1
    command = Repo.get!(ControlCommand, control.id)

    for status <- [:dispatching, :unknown] do
      command |> ControlCommand.changeset(%{status: status}) |> Repo.update!()
      assert Telephony.rollback_control_hazard_count() == 1
    end

    command
    |> ControlCommand.changeset(%{status: :submitted, completed_at: DateTime.utc_now()})
    |> Repo.update!()

    assert Telephony.rollback_control_hazard_count() == 0

    for state <- ["held", "consulting", "voicemail", "transferred"] do
      Repo.get!(Call, call.id) |> Call.changeset(%{control_state: state}) |> Repo.update!()
      assert Telephony.rollback_control_hazard_count() == 1
    end

    Repo.get!(Call, call.id)
    |> Call.changeset(%{control_state: "connected", routing_status: "waiting"})
    |> Repo.update!()

    assert Telephony.rollback_control_hazard_count() == 1

    Repo.get!(Call, call.id)
    |> Call.changeset(%{routing_status: "individual", pbx_state: %{"consult" => "bound-leg"}})
    |> Repo.update!()

    assert Telephony.rollback_control_hazard_count() == 1

    assert {:ok, _} = Telephony.end_call(call.id, subject)
    assert Telephony.rollback_control_hazard_count() == 1

    Repo.get!(Call, call.id)
    |> Call.changeset(%{cleanup_completed_at: DateTime.utc_now()})
    |> Repo.update!()

    assert Telephony.rollback_control_hazard_count() == 0
    command |> ControlCommand.changeset(%{status: :failed}) |> Repo.update!()
    assert Telephony.rollback_control_hazard_count() == 0
  end

  defp connected do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, _} =
             Telephony.provision(
               %{
                 phone_number: "+14155550100",
                 extension: "101",
                 user_id: account.user.id,
                 inbound_trunk_id: "ST_inbound",
                 outbound_trunk_id: "ST_outbound",
                 reason: "Synthetic provisioning"
               },
               subject
             )

    assert {:ok, call, :created} =
             Telephony.start_outbound(
               %{destination: "+14155550200", idempotency_key: "outbound"},
               subject
             )

    stored = Repo.get!(Call, call.id)

    stored
    |> Call.changeset(%{
      status: :answered,
      answered_at: DateTime.utc_now(),
      dispatch_status: :started,
      provider_call_id: "SC_exact"
    })
    |> Repo.update!()

    {account, subject, stored}
  end

  defp second_device(account) do
    suffix = account.tenant.slug |> String.split("-") |> List.last()

    {:ok, authentication} =
      Accounts.authenticate_view(
        account.tenant.slug,
        account.user.email,
        "correct-horse-battery-" <> suffix,
        %{name: "Second", platform: "test"}
      )

    {:ok, context} = Accounts.access_context(authentication.session_id)
    context.subject
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:comms_core, key, value)
  defp restore(key, :error), do: Application.delete_env(:comms_core, key)
end
