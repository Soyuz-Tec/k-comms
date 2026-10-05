defmodule CommsWorkers.TelephonyCleanupHandoffTest.ControlProvider do
  @behaviour CommsCore.Telephony.ProviderControlPort.Contract

  def capabilities(), do: %{}
  def authorize_destination(_), do: :ok
  def verify_event(_, _), do: {:error, :invalid_provider_webhook}

  def execute_control(request) do
    send(self(), {:unexpected_control_effect, request})
    {:error, :telephony_control_unsupported}
  end

  def cleanup_call(command) do
    result = next_result(:cleanup)
    send(self(), {:pbx_cleanup, command, CommsCore.Repo.in_transaction?(), result})
    result
  end

  def bound_call_status(command) do
    result = next_result(:bound_call_status)
    send(self(), {:bound_call_status, command, CommsCore.Repo.in_transaction?(), result})
    result
  end

  def next_result(operation) do
    key = {__MODULE__, operation}

    case Process.get(key, []) do
      [result | remaining] ->
        Process.put(key, remaining)
        result

      [] ->
        raise "unexpected telephony provider operation: #{operation}"
    end
  end
end

defmodule CommsWorkers.TelephonyCleanupHandoffTest.RoomProvider do
  def end_call(room) do
    result = CommsWorkers.TelephonyCleanupHandoffTest.ControlProvider.next_result(:room_cleanup)
    send(self(), {:room_cleanup, room, result})
    result
  end

  def create_outbound(command) do
    send(self(), {:unexpected_dial, command})
    {:error, :telephony_provider_unavailable}
  end

  def get_participant(room, identity) do
    send(self(), {:unexpected_sip_lookup, room, identity})
    {:error, :telephony_provider_unavailable}
  end
end

defmodule CommsWorkers.TelephonyCleanupHandoffTest do
  use CommsCore.DataCase, async: false

  @moduletag :integration
  @moduletag :call
  @moduletag :failure_recovery

  alias CommsCore.{Accounts, Repo, Telephony}
  alias CommsCore.Telephony.{Call, ControlCommand, Mailbox, Number, ProviderCommand, Voicemail}
  alias CommsIntegrations.Telephony.LiveKit
  alias CommsTestSupport.Fixtures
  alias CommsWorkers.{TelephonyCleanupWorker, TelephonyDispatchWorker, TelephonyExpiryWorker}
  alias __MODULE__.{ControlProvider, RoomProvider}

  setup do
    options = [
      {:comms_core, :telephony_control_adapter, ControlProvider},
      {:comms_core, :telephony_callback_adapter, LiveKit},
      {:comms_integrations, :telephony_adapter, RoomProvider}
    ]

    previous =
      Enum.map(options, fn {app, key, _} -> {app, key, Application.fetch_env(app, key)} end)

    Enum.each(options, fn {app, key, value} -> Application.put_env(app, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
        {app, key, :error} -> Application.delete_env(app, key)
      end)
    end)

    :ok
  end

  test "an ordinary SIP call still uses the existing LiveKit room-deletion adapter" do
    {_account, call} = phone_fixture(%{pbx_state: %{}, control_state: "connected"})
    call = terminal(call)
    Application.put_env(:comms_core, :telephony_control_adapter, LiveKit)
    script(:room_cleanup, [{:error, :telephony_provider_unavailable}, :ok])

    assert {:snooze, 15} = TelephonyCleanupWorker.perform(job(call))
    assert_receive {:room_cleanup, room, {:error, :telephony_provider_unavailable}}
    assert room == call.provider_room
    assert is_nil(Repo.get!(Call, call.id).cleanup_completed_at)

    assert :ok = TelephonyCleanupWorker.perform(job(call))
    assert_receive {:room_cleanup, ^room, :ok}
    assert Repo.get!(Call, call.id).cleanup_completed_at
    assert :ok = TelephonyCleanupWorker.perform(job(call))
    assert :ok = Telephony.complete_cleanup(call.id, :execute, TelephonyCleanupWorker)
    refute_received {:room_cleanup, _, _}
    refute_received {:pbx_cleanup, _, _, _}
    refute_provider_origination()
  end

  test "a partial PBX teardown cannot certify cleanup even if a LiveKit room is already absent" do
    {_account, call} = phone_fixture(%{control_state: "consulting"})
    call = terminal(call)

    script(:cleanup, [
      {:error, :telephony_outcome_unknown},
      {:error, :telephony_provider_unavailable},
      {:error, :telephony_pbx_binding_invalid},
      :ok
    ])

    for failure <- [
          :telephony_outcome_unknown,
          :telephony_provider_unavailable,
          :telephony_pbx_binding_invalid
        ] do
      assert {:snooze, 15} = TelephonyCleanupWorker.perform(job(call))

      assert_receive {:pbx_cleanup, %ProviderCommand{} = command, true, {:error, ^failure}}
      assert command.call_id == call.id
      assert command.pbx_state == call.pbx_state
      assert command.provider_room == call.provider_room
      assert command.status == :ended
      persisted = Repo.get!(Call, call.id)
      assert is_nil(persisted.cleanup_completed_at)
      assert is_nil(persisted.cleanup_claimed_at)
    end

    assert :ok = TelephonyCleanupWorker.perform(job(call))
    assert_receive {:pbx_cleanup, %ProviderCommand{call_id: id}, true, :ok}
    assert id == call.id
    assert Repo.get!(Call, call.id).cleanup_completed_at
    assert :ok = TelephonyCleanupWorker.perform(job(call))
    refute_received {:pbx_cleanup, _, _, _}
    refute_received {:room_cleanup, _, _}
    refute_provider_origination()
  end

  test "a generic room success cannot certify a PBX call or replace its persisted binding" do
    {_account, call} = phone_fixture()
    call = terminal(call)
    assert {:ok, %ProviderCommand{}} = Telephony.claim_cleanup(call.id, TelephonyCleanupWorker)

    assert {:error, :telephony_pbx_binding_invalid} =
             Telephony.complete_cleanup(call.id, :ok, TelephonyCleanupWorker)

    assert is_nil(Repo.get!(Call, call.id).cleanup_completed_at)
    refute_received {:pbx_cleanup, _, _, _}
    refute_received {:room_cleanup, _, _}
  end

  test "cleanup effects use the current locked PBX binding rather than the earlier claim snapshot" do
    {_account, call} = phone_fixture(%{control_state: "held"})
    call = terminal(call)

    assert {:ok, %ProviderCommand{pbx_state: original}} =
             Telephony.claim_cleanup(call.id, TelephonyCleanupWorker)

    binding = Map.put(original, "consult", "late-consult-" <> call.id)
    updated = change_call(call, %{pbx_state: binding, control_state: "consulting"})
    script(:cleanup, [:ok])

    assert :ok = Telephony.complete_cleanup(call.id, :execute, TelephonyCleanupWorker)
    assert_receive {:pbx_cleanup, %ProviderCommand{} = command, true, :ok}
    assert command.pbx_state == binding
    refute command.pbx_state == original
    assert command.control_state == "consulting"
    assert command.expires_at == updated.expires_at
    assert command.tenant_id == call.tenant_id
    assert command.provider_identity == call.provider_identity
    assert command.route_id == call.route_id
    assert Repo.get!(Call, call.id).cleanup_completed_at
  end

  test "a call that is active at effect time cannot be torn down by an earlier terminal claim" do
    {_account, call} = phone_fixture()
    call = terminal(call)
    assert {:ok, %ProviderCommand{}} = Telephony.claim_cleanup(call.id, TelephonyCleanupWorker)
    change_call(call, %{status: :answered, ended_at: nil, end_reason: nil})

    assert {:error, :telephony_cleanup_not_due} =
             Telephony.complete_cleanup(call.id, :execute, TelephonyCleanupWorker)

    assert {:snooze, 5} = TelephonyCleanupWorker.perform(job(call))
    persisted = Repo.get!(Call, call.id)
    assert persisted.status == :answered
    assert is_nil(persisted.cleanup_completed_at)
    refute_received {:pbx_cleanup, _, _, _}
    refute_provider_origination()
  end

  test "an unconfigured worker cannot claim cleanup, certify it, or inspect a transferred pair" do
    {_account, call} = phone_fixture(%{control_state: "transferred"})
    assert {:error, :forbidden} = Telephony.expire(call.id, __MODULE__)
    call = terminal(call)
    assert {:error, :forbidden} = Telephony.claim_cleanup(call.id, __MODULE__)
    assert {:error, :forbidden} = Telephony.complete_cleanup(call.id, :execute, __MODULE__)
    assert is_nil(Repo.get!(Call, call.id).cleanup_completed_at)
    refute_received {:pbx_cleanup, _, _, _}
    refute_received {:bound_call_status, _, _, _}
  end

  test "expected app, SIP, and room departure after handoff preserves the transferred external pair" do
    {account, call} = phone_fixture(%{control_state: "transferred"})

    for {type, identity} <- [
          {"participant_left", call.app_identity},
          {"participant_left", call.provider_identity},
          {"participant_connection_aborted", call.provider_identity},
          {"room_finished", nil}
        ] do
      assert {:ok, view, :applied} = Telephony.callback(departure(call, type, identity), LiveKit)
      assert view.status == :answered
      persisted = Repo.get!(Call, call.id)
      assert persisted.pbx_state == call.pbx_state
      assert is_nil(persisted.ended_at)
      assert is_nil(persisted.app_reconnect_deadline)
      assert is_nil(persisted.cleanup_completed_at)
    end

    assert {:snooze, 5} = TelephonyCleanupWorker.perform(job(call))
    assert {:ok, view} = Telephony.get_call(call.id, Fixtures.subject(account))
    refute view.can_join

    assert {:error, :invalid_call_action} =
             Telephony.join(call.id, Fixtures.subject(account), fn _ ->
               flunk("a handed-off call must not mint another browser admission")
             end)

    refute cleanup_enqueued?(call.id)
    assert expiry_enqueued?(call.id)
    refute_received {:pbx_cleanup, _, _, _}
    refute_provider_origination()
  end

  test "claimed but uncertain transfer completion also survives an expected LiveKit departure" do
    for status <- [:unknown, :dispatching] do
      {account, call} = phone_fixture(%{control_state: "consulting"})
      command = transfer_command(account, call, status, now())
      call = change_call(call, %{app_reconnect_deadline: DateTime.add(now(), -1, :second)})

      assert {:ok, view, :applied} =
               Telephony.callback(
                 departure(call, "participant_left", call.provider_identity),
                 LiveKit
               )

      assert view.status == :answered
      assert Repo.get!(ControlCommand, command.id).status == status
      assert Repo.get!(Call, call.id).pbx_state == call.pbx_state
      assert {:ok, view} = Telephony.get_call(call.id, Fixtures.subject(account))
      refute view.can_join

      assert {:error, :invalid_call_action} =
               Telephony.join(call.id, Fixtures.subject(account), fn _ ->
                 flunk("an uncertain claimed handoff must not mint a browser admission")
               end)

      assert {:snooze, 5} = TelephonyCleanupWorker.perform(job(call))
      refute cleanup_enqueued?(call.id)
      script(:bound_call_status, [{:ok, :active}])
      assert {:snooze, seconds} = TelephonyExpiryWorker.perform(job(call))
      assert seconds in 1..5
      assert_receive {:bound_call_status, %ProviderCommand{call_id: id}, true, {:ok, :active}}
      assert id == call.id
      assert Repo.get!(Call, call.id).status == :answered
    end

    refute_received {:pbx_cleanup, _, _, _}
    refute_provider_origination()
  end

  test "a transfer that was never claimed cannot suppress the remote party hanging up" do
    for status <- [:pending, :dispatching, :unknown] do
      {account, call} = phone_fixture(%{control_state: "consulting"})
      transfer_command(account, call, status, nil)

      assert {:ok, view, :applied} =
               Telephony.callback(
                 departure(call, "participant_left", call.provider_identity),
                 LiveKit
               )

      assert view.status == :ended
      assert Repo.get!(Call, call.id).end_reason == "participant_left"
      assert cleanup_enqueued?(call.id)
    end

    refute_received {:bound_call_status, _, _, _}
    refute_provider_origination()
  end

  test "a transferred pair stays active through provider uncertainty until actual external absence" do
    {_account, call} = phone_fixture(%{control_state: "transferred"})

    script(:bound_call_status, [
      {:error, :telephony_provider_unavailable},
      {:ok, :active},
      {:ok, :ended}
    ])

    for result <- [{:error, :telephony_provider_unavailable}, {:ok, :active}] do
      assert {:snooze, seconds} = TelephonyExpiryWorker.perform(job(call))
      assert seconds in 1..5
      assert_receive {:bound_call_status, %ProviderCommand{} = observed, true, ^result}
      assert observed.call_id == call.id
      assert observed.pbx_state == call.pbx_state
      assert observed.provider_identity == call.provider_identity
      assert Repo.get!(Call, call.id).status == :answered
      refute cleanup_enqueued?(call.id)
    end

    assert :ok = TelephonyExpiryWorker.perform(job(call))
    assert_receive {:bound_call_status, %ProviderCommand{call_id: id}, true, {:ok, :ended}}
    assert id == call.id
    persisted = Repo.get!(Call, call.id)
    assert persisted.status == :ended
    assert persisted.end_reason == "transferred_remote_end"
    assert cleanup_enqueued?(call.id)

    script(:cleanup, [:ok])
    assert :ok = TelephonyCleanupWorker.perform(job(call))
    assert_receive {:pbx_cleanup, %ProviderCommand{pbx_state: bindings}, true, :ok}
    assert bindings == call.pbx_state
    assert Repo.get!(Call, call.id).cleanup_completed_at
    assert :ok = TelephonyDispatchWorker.perform(job(call))
    refute_provider_origination()
  end

  test "maximum duration still terminates a handed-off pair without relying on provider status" do
    {_account, call} = phone_fixture(%{control_state: "transferred"})
    call = change_call(call, %{expires_at: DateTime.add(now(), -1, :second)})

    assert :ok = TelephonyExpiryWorker.perform(job(call))
    persisted = Repo.get!(Call, call.id)
    assert persisted.status == :ended
    assert persisted.end_reason == "maximum_duration"
    assert cleanup_enqueued?(call.id)
    refute_received {:bound_call_status, _, _, _}

    script(:cleanup, [:ok])
    assert :ok = TelephonyCleanupWorker.perform(job(call))
    assert_receive {:pbx_cleanup, %ProviderCommand{pbx_state: bindings}, true, :ok}
    assert bindings == call.pbx_state
    assert Repo.get!(Call, call.id).cleanup_completed_at
    refute_provider_origination()
  end

  test "explicit end and session revocation both clean a transferred pair rather than preserving it" do
    for operation <- [:end, :revoke] do
      {account, call} = phone_fixture(%{control_state: "transferred"})

      case operation do
        :end -> assert {:ok, _} = Telephony.end_call(call.id, Fixtures.subject(account))
        :revoke -> assert :ok = Accounts.revoke_session(account.session.id, account.user.id)
      end

      assert Repo.get!(Call, call.id).status == :ended
      assert cleanup_enqueued?(call.id)
      script(:cleanup, [:ok])
      assert :ok = TelephonyCleanupWorker.perform(job(call))
      assert_receive {:pbx_cleanup, %ProviderCommand{} = command, true, :ok}
      assert command.call_id == call.id
      assert command.pbx_state == call.pbx_state
      assert Repo.get!(Call, call.id).cleanup_completed_at
    end

    refute_received {:bound_call_status, _, _, _}
    refute_provider_origination()
  end

  test "intentional voicemail room departure preserves the bounded caller until real external absence" do
    {account, call} = phone_fixture(%{control_state: "voicemail"})
    {call, voicemail} = pending_voicemail(account, call, DateTime.add(now(), 30, :second))

    for {type, identity} <- [
          {"participant_left", call.app_identity},
          {"participant_left", call.provider_identity},
          {"room_finished", nil}
        ] do
      assert {:ok, view, :applied} = Telephony.callback(departure(call, type, identity), LiveKit)
      assert view.status == :answered
      assert Repo.get!(Voicemail, voicemail.id).status == :pending
      refute cleanup_enqueued?(call.id)
    end

    assert {:ok, view} = Telephony.get_call(call.id, Fixtures.subject(account))
    refute view.can_join

    assert {:error, :invalid_call_action} =
             Telephony.join(call.id, Fixtures.subject(account), fn _ ->
               flunk("a caller recording voicemail must not receive a browser rejoin")
             end)

    script(:bound_call_status, [{:ok, :active}, {:ok, :ended}])
    assert {:snooze, seconds} = TelephonyExpiryWorker.perform(job(call))
    assert seconds in 1..5

    assert_receive {:bound_call_status, %ProviderCommand{control_state: "voicemail"} = observed,
                    true, {:ok, :active}}

    assert observed.pbx_state == call.pbx_state
    assert Repo.get!(Call, call.id).status == :answered
    assert :ok = TelephonyExpiryWorker.perform(job(call))
    assert_receive {:bound_call_status, %ProviderCommand{}, true, {:ok, :ended}}
    assert Repo.get!(Call, call.id).end_reason == "voicemail_remote_end"
    assert cleanup_enqueued?(call.id)

    script(:cleanup, [:ok])
    assert :ok = TelephonyCleanupWorker.perform(job(call))
    assert_receive {:pbx_cleanup, %ProviderCommand{pbx_state: binding}, true, :ok}
    assert binding == call.pbx_state
    assert Repo.get!(Call, call.id).cleanup_completed_at
    refute_provider_origination()
  end

  test "a pending voicemail's fixed recording deadline ends its caller through a provider outage" do
    {account, call} = phone_fixture(%{control_state: "voicemail"})
    {call, voicemail} = pending_voicemail(account, call, DateTime.add(now(), 30, :second))
    script(:bound_call_status, [{:error, :telephony_provider_unavailable}])

    assert {:snooze, seconds} = TelephonyExpiryWorker.perform(job(call))
    assert seconds in 1..5

    assert_receive {:bound_call_status, %ProviderCommand{}, true,
                    {:error, :telephony_provider_unavailable}}

    assert Repo.get!(Voicemail, voicemail.id).recording_deadline == voicemail.recording_deadline
    assert Repo.get!(Call, call.id).expires_at == call.expires_at

    voicemail
    |> Ecto.Changeset.change(recording_deadline: DateTime.add(now(), -1, :second))
    |> Repo.update!()

    assert :ok = TelephonyExpiryWorker.perform(job(call))
    assert Repo.get!(Call, call.id).status == :ended
    assert cleanup_enqueued?(call.id)
    refute_received {:bound_call_status, _, _, _}
    script(:cleanup, [:ok])
    assert :ok = TelephonyCleanupWorker.perform(job(call))
    assert_receive {:pbx_cleanup, %ProviderCommand{}, true, :ok}
    assert Repo.get!(Call, call.id).cleanup_completed_at
    refute_provider_origination()
  end

  test "a completed pinned voicemail capture ends its caller without waiting for the old deadline" do
    {account, call} = phone_fixture(%{control_state: "voicemail"})
    {call, voicemail} = pending_voicemail(account, call, DateTime.add(now(), 30, :second))

    voicemail
    |> Ecto.Changeset.change(%{
      status: :available,
      object_version_id: "synthetic-pinned-version",
      object_etag: "synthetic-pinned-etag",
      checksum_sha256: String.duplicate("a", 64),
      verified_checksum_sha256: String.duplicate("a", 64),
      byte_size: 128,
      duration_seconds: 2,
      available_at: now()
    })
    |> Repo.update!()

    assert :ok = TelephonyExpiryWorker.perform(job(call))
    persisted = Repo.get!(Call, call.id)
    assert persisted.status == :ended
    assert persisted.end_reason == "voicemail_capture_complete"
    assert cleanup_enqueued?(call.id)
    refute_received {:bound_call_status, _, _, _}
    script(:cleanup, [:ok])
    assert :ok = TelephonyCleanupWorker.perform(job(call))
    assert_receive {:pbx_cleanup, %ProviderCommand{}, true, :ok}
    assert Repo.get!(Call, call.id).cleanup_completed_at
    refute_provider_origination()
  end

  defp phone_fixture(overrides \\ %{}) do
    account = Fixtures.account_fixture()
    suffix = System.unique_integer([:positive, :monotonic]) |> Integer.to_string()
    phone_number = "+1555" <> String.pad_leading(suffix, 7, "0")

    number =
      %Number{}
      |> Number.changeset(%{
        tenant_id: account.tenant.id,
        user_id: account.user.id,
        phone_number: phone_number,
        extension: "101",
        inbound_trunk_id: "ST_cleanup_inbound",
        outbound_trunk_id: "ST_cleanup_outbound"
      })
      |> Repo.insert!()

    timestamp = now()
    id = Ecto.UUID.generate()

    attrs =
      Map.merge(
        %{
          tenant_id: account.tenant.id,
          number_id: number.id,
          user_id: account.user.id,
          direction: :outbound,
          status: :answered,
          from_number: phone_number,
          to_number: "+15555550199",
          extension: number.extension,
          inbound_trunk_id: number.inbound_trunk_id,
          outbound_trunk_id: number.outbound_trunk_id,
          provider_room: "telephony-cleanup-" <> id,
          provider_identity: "sip-cleanup-" <> id,
          provider_call_id: "SC_cleanup_" <> id,
          answer_session_id: account.session.id,
          answer_device_id: account.device.id,
          app_identity: "app-cleanup-" <> id,
          app_connected_at: timestamp,
          app_provider_sid: "PA_cleanup_" <> id,
          app_event_at: timestamp,
          started_at: DateTime.add(timestamp, -30, :second),
          answered_at: DateTime.add(timestamp, -20, :second),
          expires_at: DateTime.add(timestamp, 45, :second),
          dispatch_status: :started,
          control_state: "held",
          pbx_state: %{
            "external" => "external-" <> id,
            "app" => "app-" <> id,
            "mixing" => "mixing-" <> id,
            "holding" => "holding-" <> id,
            "consult" => "consult-" <> id,
            "recording" => "recording-" <> id
          }
        },
        overrides
      )

    {account, %Call{id: id} |> Call.changeset(attrs) |> Repo.insert!()}
  end

  defp transfer_command(account, call, status, claimed_at) do
    %ControlCommand{}
    |> ControlCommand.changeset(%{
      tenant_id: account.tenant.id,
      call_id: call.id,
      user_id: account.user.id,
      session_id: account.session.id,
      device_id: account.device.id,
      action: :complete_transfer,
      status: status,
      claimed_at: claimed_at,
      idempotency_key: "transfer-completion-" <> Ecto.UUID.generate(),
      payload_hash: String.duplicate("a", 64),
      expires_at: DateTime.add(now(), 60, :second)
    })
    |> Repo.insert!()
  end

  defp pending_voicemail(account, call, deadline) do
    box =
      %Mailbox{}
      |> Mailbox.changeset(%{
        tenant_id: account.tenant.id,
        number_id: call.number_id,
        user_id: account.user.id,
        enabled: true,
        retention_days: 30,
        notice_media: "sound:custom/recording-notice"
      })
      |> Repo.insert!()

    recording_name = "kc_vm_" <> String.replace(call.id, "-", "")
    call = change_call(call, %{pbx_state: Map.put(call.pbx_state, "recording", recording_name)})

    voicemail =
      %Voicemail{}
      |> Voicemail.changeset(%{
        tenant_id: account.tenant.id,
        mailbox_id: box.id,
        call_id: call.id,
        user_id: account.user.id,
        recording_name: recording_name,
        notice_media: box.notice_media,
        recording_deadline: deadline,
        retention_expires_at: DateTime.add(now(), 30 * 86_400, :second),
        object_key: "telephony/voicemail/" <> account.tenant.id <> "/" <> call.id
      })
      |> Repo.insert!()

    {call, voicemail}
  end

  defp departure(call, type, identity) do
    %{
      event_id: "cleanup-departure-" <> Ecto.UUID.generate(),
      event_type: type,
      room: call.provider_room,
      participant_identity: identity,
      participant_kind: if(identity == call.app_identity, do: :standard, else: :sip),
      participant_sid: if(identity, do: "PA_cleanup_departure_" <> call.id, else: nil),
      occurred_at: now()
    }
  end

  defp terminal(call),
    do: change_call(call, %{status: :ended, ended_at: now(), end_reason: "synthetic_cleanup"})

  defp change_call(call, changes),
    do: Repo.get!(Call, call.id) |> Ecto.Changeset.change(changes) |> Repo.update!()

  defp script(operation, results), do: Process.put({ControlProvider, operation}, results)
  defp job(call), do: %Oban.Job{args: %{"call_id" => call.id}}
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp cleanup_enqueued?(id), do: job_enqueued?(id, "CommsWorkers.TelephonyCleanupWorker")
  defp expiry_enqueued?(id), do: job_enqueued?(id, "CommsWorkers.TelephonyExpiryWorker")

  defp job_enqueued?(id, worker),
    do:
      Repo.exists?(
        from(job in Oban.Job,
          where: job.worker == ^worker and fragment("?->>'call_id'", job.args) == ^id
        )
      )

  defp refute_provider_origination do
    refute_received {:unexpected_dial, _}
    refute_received {:unexpected_sip_lookup, _, _}
    refute_received {:unexpected_control_effect, _}
  end
end
