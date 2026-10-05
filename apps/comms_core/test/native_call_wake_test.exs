defmodule CommsCore.NativeCallWakeTest.Provider do
  @behaviour CommsCore.Notifications.NativePushProviderPort.Contract
  def status(), do: %{status: :available, channels: ["apns_voip", "fcm"]}

  def deliver(delivery, _deadline) do
    send(self(), {:native_provider_effect, delivery})
    Process.get(:native_provider_result, :ok)
  end
end

defmodule CommsCore.NativeCallWakeTest.CallOwner do
  @behaviour CommsCore.Notifications.NativeCallWakePort.Contract
  def recipients(_), do: {:ok, Process.get(:native_recipient_ids, [])}

  def authorize(_) do
    if Process.get(:native_call_eligible, true),
      do: {:ok, DateTime.add(DateTime.utc_now(), 60, :second)},
      else: {:error, :forbidden}
  end

  def admit(request, _subject, issuer) do
    with {:ok, _} <- authorize(request), {:ok, credential} <- issuer.(request.owner, request) do
      {:ok, %{data: %{id: request.call_id}, credential: credential}}
    end
  end
end

defmodule CommsCore.NativeCallWakeTest do
  use CommsCore.DataCase, async: false
  alias CommsCore.{Accounts, Notifications, Repo}
  alias CommsCore.Accounts.{Session, User}

  alias CommsCore.Notifications.{
    NativeCallWake,
    NativeDelivery,
    NativePushRegistration,
    NativePushView
  }

  alias CommsCore.Security.NativePushBox
  alias CommsTestSupport.Fixtures
  @moduletag :integration
  @moduletag :notifications

  setup do
    config = [
      native_push_enabled: true,
      native_push_encryption_key: :crypto.strong_rand_bytes(32),
      native_push_encryption_keys: nil,
      native_call_wake_adapter: __MODULE__.CallOwner,
      native_push_provider_adapter: __MODULE__.Provider,
      native_push_platforms: [
        %{
          platform: "ios",
          channel: "apns_voip",
          application_id: "com.synthetic.native",
          environment: "sandbox",
          device_qualified: true
        }
      ]
    ]

    previous = Enum.map(config, fn {key, _} -> {key, Application.fetch_env(:comms_core, key)} end)
    Enum.each(config, fn {key, value} -> Application.put_env(:comms_core, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn {key, old} ->
        case old do
          {:ok, value} -> Application.put_env(:comms_core, key, value)
          :error -> Application.delete_env(:comms_core, key)
        end
      end)
    end)

    account = Fixtures.account_fixture()
    %{account: account, subject: Fixtures.subject(account)}
  end

  test "default-off readiness does not register or reveal transport material", %{subject: subject} do
    Application.put_env(:comms_core, :native_push_enabled, false)
    assert {:ok, %{enabled: false}} = Notifications.native_push_config(subject)

    assert {:error, :native_push_unavailable} =
             Notifications.register_native_push(attrs(), subject)

    assert Repo.aggregate(NativePushRegistration, :count) == 0
  end

  test "safe receipts and AAD bind exact device generation without token/hash/ciphertext", %{
    subject: subject
  } do
    assert {:ok, %{registration: %NativePushView{} = view}} =
             Notifications.register_native_push(attrs(), subject)

    stored = Repo.get!(NativePushRegistration, view.id)
    refute inspect(stored) =~ attrs().token
    refute inspect(view) =~ attrs().token

    assert Map.keys(Map.from_struct(view)) |> Enum.sort() ==
             Enum.sort([
               :id,
               :device_id,
               :version,
               :platform,
               :channel,
               :application_id,
               :environment,
               :status,
               :expires_at
             ])

    context = context(stored)
    assert {:ok, token} = NativePushBox.decrypt(Map.from_struct(stored), context)
    assert token == attrs().token

    for changed <- [
          %{context | version: 2},
          %{context | tenant_id: Ecto.UUID.generate()},
          %{context | application_id: "com.other.native"},
          %{context | channel: "apns_alert"},
          %{context | environment: "production"}
        ] do
      assert {:error, _} = NativePushBox.decrypt(Map.from_struct(stored), changed)
    end
  end

  test "exact registration shape, approved app/channel and duplicate atom/string keys fail closed",
       %{subject: subject} do
    for input <- [
          Map.put(attrs(), :caller, "private"),
          Map.put(attrs(), "token", attrs().token),
          %{attrs() | application_id: "com.other.native"},
          %{attrs() | channel: "fcm"},
          %{attrs() | expected_version: -1},
          %{attrs() | token: "invalid\r\n"}
        ] do
      assert {:error, :native_push_unavailable} =
               Notifications.register_native_push(input, subject)
    end

    assert Repo.aggregate(NativePushRegistration, :count) == 0
  end

  test "CAS replay is exact and a stale revoke cannot delete a replacement", %{subject: subject} do
    input = attrs()

    assert {:ok, %{registration: first, replayed: false}} =
             Notifications.register_native_push(input, subject)

    assert {:ok, %{registration: replay, replayed: true}} =
             Notifications.register_native_push(%{input | expected_version: 1}, subject)

    assert replay.id == first.id

    assert {:ok, %{registration: second, replayed: false}} =
             Notifications.register_native_push(
               %{input | expected_version: 1, token: String.duplicate("b", 64)},
               subject
             )

    assert second.version == 2

    assert {:error, :native_push_version_conflict} =
             Notifications.revoke_native_push(
               %{channel: "apns_voip", expected_version: 1},
               subject
             )

    assert Repo.get!(NativePushRegistration, first.id).status == "active"
  end

  test "a transport token cannot cross users even after revocation", %{subject: subject} do
    assert {:ok, %{registration: first}} = Notifications.register_native_push(attrs(), subject)

    assert {:ok, _} =
             Notifications.revoke_native_push(
               %{channel: "apns_voip", expected_version: first.version},
               subject
             )

    other = Fixtures.account_fixture()

    assert {:error, :native_push_unavailable} =
             Notifications.register_native_push(attrs(), Fixtures.subject(other))

    assert is_nil(Repo.get!(NativePushRegistration, first.id).ciphertext)
  end

  test "same-user fresh-device login rebinds only a wiped terminal installation and fences old wakes",
       %{account: account, subject: subject} do
    row = registration(subject)
    intent = wake(row, "sent")
    assert :ok = Accounts.revoke_session(account.session.id, account.user.id)
    current = authenticate_owner(account)
    assert current.device_id != subject.device_id
    assert {:ok, []} = Notifications.native_push_registrations(current)

    assert {:error, :native_push_unavailable} =
             Notifications.register_native_push(
               %{attrs() | installation_id: Ecto.UUID.generate()},
               current
             )

    assert {:error, :native_push_version_conflict} =
             Notifications.register_native_push(
               %{attrs() | expected_version: row.version},
               current
             )

    assert {:ok, %{registration: rebound, replayed: false}} =
             Notifications.register_native_push(attrs(), current)

    assert rebound.id == row.id && rebound.version == row.version + 1
    stored = Repo.get!(NativePushRegistration, row.id)
    assert stored.device_id == current.device_id && stored.session_id == current.session_id
    assert Repo.get!(NativeCallWake, intent.id).status == "revoked"

    assert {:error, :native_push_unavailable} =
             Notifications.admit_native_call_wake(intent.id, current, fn _, _ ->
               flunk("Old device wake issued a replacement-session credential")
             end)

    assert {:error, :native_push_unavailable} =
             Notifications.revoke_native_push(
               %{channel: row.channel, expected_version: row.version},
               subject
             )

    assert Repo.get!(NativePushRegistration, row.id).status == "active"
  end

  test "same-user installation cannot steal a live registration on another current device", %{
    account: account,
    subject: subject
  } do
    row = registration(subject)
    current = authenticate_owner(account)

    assert {:error, :native_push_unavailable} =
             Notifications.register_native_push(attrs(), current)

    assert Repo.get!(NativePushRegistration, row.id).device_id == subject.device_id
  end

  test "provider uncertainty remains durable and Oban retry never re-emits", %{subject: subject} do
    row = registration(subject)
    wake = wake(row)
    Process.put(:native_provider_result, {:error, :uncertain})

    assert {:ok, :complete} =
             Notifications.dispatch_native_call_wake(
               wake.id,
               row.version,
               CommsWorkers.NativeCallWakeWorker
             )

    assert_received {:native_provider_effect, %NativeDelivery{} = delivered}
    refute inspect(delivered) =~ attrs().token
    refute Map.has_key?(Map.from_struct(delivered), :call_id)
    assert Repo.get!(NativeCallWake, wake.id).status == "uncertain"

    assert {:ok, :complete} =
             Notifications.dispatch_native_call_wake(
               wake.id,
               row.version,
               CommsWorkers.NativeCallWakeWorker
             )

    refute_received {:native_provider_effect, _}
  end

  test "expired, foreign and replayed intents never invoke credential issuance", %{
    subject: subject
  } do
    row = registration(subject)
    wake = wake(row, "sent")

    issuer = fn _, _ ->
      send(self(), :credential_issued)
      {:ok, %{synthetic: true}}
    end

    foreign = Fixtures.subject(Fixtures.account_fixture())

    assert {:error, :native_push_unavailable} =
             Notifications.admit_native_call_wake(wake.id, foreign, issuer)

    refute_received :credential_issued

    assert {:ok, %{owner: "conversation"}} =
             Notifications.admit_native_call_wake(wake.id, subject, issuer)

    assert_received :credential_issued

    assert {:error, :native_push_unavailable} =
             Notifications.admit_native_call_wake(wake.id, subject, issuer)

    refute_received :credential_issued
    expired = wake(row, "sent", -1)

    assert {:error, :native_push_unavailable} =
             Notifications.admit_native_call_wake(expired.id, subject, issuer)

    refute_received :credential_issued
  end

  test "current owner eligibility withdrawal blocks both send and admission", %{subject: subject} do
    row = registration(subject)
    pending = wake(row)
    sent = wake(row, "sent")
    Process.put(:native_call_eligible, false)

    assert {:ok, :complete} =
             Notifications.dispatch_native_call_wake(
               pending.id,
               row.version,
               CommsWorkers.NativeCallWakeWorker
             )

    refute_received {:native_provider_effect, _}

    assert {:error, :native_push_unavailable} =
             Notifications.admit_native_call_wake(sent.id, subject, fn _, _ ->
               flunk("withdrawn owner issued a credential")
             end)
  end

  test "session revocation wipes ciphertext and terminates pending wake in the actual owner transaction",
       %{account: account, subject: subject} do
    row = registration(subject)
    intent = wake(row)
    assert :ok = Accounts.revoke_session(account.session.id, account.user.id)

    assert %NativePushRegistration{
             status: "revoked",
             ciphertext: nil,
             nonce: nil,
             tag: nil,
             key_id: nil
           } = Repo.get!(NativePushRegistration, row.id)

    assert Repo.get!(NativeCallWake, intent.id).status == "revoked"

    assert {:error, :native_push_unavailable} =
             Notifications.register_native_push(
               %{attrs() | expected_version: row.version},
               subject
             )
  end

  test "an expired origin session and changed user version cannot authorize a wake", %{
    account: account,
    subject: subject
  } do
    row = registration(subject)
    intent = wake(row, "sent")

    Repo.get!(User, account.user.id)
    |> Ecto.Changeset.change(lock_version: Repo.get!(User, account.user.id).lock_version + 1)
    |> Repo.update!()

    assert {:error, :native_push_unavailable} =
             Notifications.admit_native_call_wake(intent.id, subject, fn _, _ ->
               flunk("stale user version issued")
             end)

    Repo.get!(Session, account.session.id)
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:ok, :complete} =
             Notifications.dispatch_native_call_wake(
               intent.id,
               row.version,
               CommsWorkers.NativeCallWakeWorker
             )

    refute_received {:native_provider_effect, _}
  end

  test "worker ownership and malformed cursors cannot authorize reconciliation or provider work",
       %{subject: subject} do
    row = registration(subject)
    intent = wake(row)
    assert {:error, :forbidden} = Notifications.reconcile_native_push(__MODULE__, %{})

    assert {:error, :forbidden} =
             Notifications.reconcile_native_push(CommsWorkers.NativePushReconcilerWorker, %{
               "after_id" => "invalid"
             })

    assert {:ok, :complete} =
             Notifications.dispatch_native_call_wake(intent.id, row.version, __MODULE__)

    refute_received {:native_provider_effect, _}
  end

  test "final user erasure removes retained fingerprint and wakes on the declared two-owner command",
       %{account: account, subject: subject} do
    row = registration(subject)
    _intent = wake(row)

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               command =
                 CommsCore.Accounts.NotificationCommand.user_erased(
                   account.tenant.id,
                   account.user.id
                 )

               CommsCore.Accounts.NotificationPort.execute(command)
             end)

    assert Repo.aggregate(NativePushRegistration, :count) == 0
    assert Repo.aggregate(NativeCallWake, :count) == 0
  end

  test "actual Calls owner admits a limited human only while membership and call remain current",
       %{account: account} do
    Application.put_env(
      :comms_core,
      :native_call_wake_adapter,
      CommsIntegrations.NativePush.CallOwner
    )

    member = Fixtures.user_fixture(account).user
    [local, _] = String.split(member.email, "@", parts: 2)
    suffix = String.replace_prefix(local, "member-", "")
    owner = Fixtures.subject(account)

    assert {:ok, _} =
             CommsCore.Conversations.add_member(
               account.conversation.id,
               member.id,
               :member,
               owner
             )

    member |> Ecto.Changeset.change(access_scope: :conversation_only) |> Repo.update!()

    assert {:ok, authentication} =
             Accounts.authenticate_view(
               account.tenant.slug,
               member.email,
               "correct-horse-battery-#{suffix}",
               %{name: "Synthetic native", platform: "ios"}
             )

    assert {:ok, context} = Accounts.access_context(authentication.session_id)
    current = context.subject
    row = registration(current)
    assert {:ok, call, :created} = CommsCore.AudioCalls.start(account.conversation.id, owner)

    event = %CommsCore.Outbox.Event{
      id: Ecto.UUID.generate(),
      tenant_id: account.tenant.id,
      event_type: "call.started.v1",
      aggregate_type: "call",
      aggregate_id: call.id,
      payload: %{conversation_id: account.conversation.id},
      inserted_at: DateTime.utc_now()
    }

    assert :ok = CommsCore.Notifications.NativePush.enqueue(event)
    intent = Repo.get_by!(NativeCallWake, registration_id: row.id, call_id: call.id)

    assert DateTime.compare(intent.expires_at, DateTime.add(event.inserted_at, 30, :second)) !=
             :gt

    assert {:ok, :complete} =
             Notifications.dispatch_native_call_wake(
               intent.id,
               row.version,
               CommsWorkers.NativeCallWakeWorker
             )

    assert_received {:native_provider_effect, _}

    assert {:ok, %{owner: "conversation", data: actual}} =
             Notifications.admit_native_call_wake(intent.id, current, fn "conversation",
                                                                         %CommsCore.AudioCalls.CredentialRequest{
                                                                           call_id: id
                                                                         } ->
               assert id == call.id
               {:ok, %{synthetic: true}}
             end)

    assert actual.id == call.id

    assert {:ok, _} =
             CommsCore.AudioCalls.end_call(
               account.conversation.id,
               call.id,
               %{reason: "owner_ended"},
               owner,
               fn _ -> :ok end
             )

    assert {:ok, second, :created} = CommsCore.AudioCalls.start(account.conversation.id, owner)

    stale =
      wake(row, "sent")
      |> Ecto.Changeset.change(call_id: second.id, conversation_id: account.conversation.id)
      |> Repo.update!()

    assert {:ok, _} =
             CommsCore.AudioCalls.end_call(
               account.conversation.id,
               second.id,
               %{reason: "owner_ended"},
               owner,
               fn _ -> :ok end
             )

    assert {:error, :native_push_unavailable} =
             Notifications.admit_native_call_wake(stale.id, current, fn _, _ ->
               flunk("Ended call issued a wake credential")
             end)
  end

  test "actual Calls owner fences current device-session revocation and respects explicit readmission",
       %{account: account} do
    Application.put_env(
      :comms_core,
      :native_call_wake_adapter,
      CommsIntegrations.NativePush.CallOwner
    )

    member = Fixtures.user_fixture(account).user
    owner = Fixtures.subject(account)

    assert {:ok, _} =
             CommsCore.Conversations.add_member(
               account.conversation.id,
               member.id,
               :member,
               owner
             )

    previous = authenticate_member(account, member)
    assert {:ok, call, :created} = CommsCore.AudioCalls.start(account.conversation.id, owner)

    assert {:ok, _, _} =
             CommsCore.AudioCalls.with_join_authorized(
               account.conversation.id,
               call.id,
               previous,
               fn _ -> {:ok, %{synthetic: true}} end
             )

    assert {:ok, _} =
             CommsCore.AudioCalls.revoke_for_sessions(
               account.tenant.id,
               [previous.session_id],
               "owner_removed"
             )

    current = authenticate_member(account, member)
    row = registration(current)

    event = %CommsCore.Outbox.Event{
      id: Ecto.UUID.generate(),
      tenant_id: account.tenant.id,
      event_type: "call.started.v1",
      aggregate_type: "call",
      aggregate_id: call.id,
      payload: %{conversation_id: account.conversation.id},
      inserted_at: DateTime.utc_now()
    }

    assert :ok = CommsCore.Notifications.NativePush.enqueue(event)
    intent = Repo.get_by!(NativeCallWake, registration_id: row.id, call_id: call.id)

    assert {:ok, :complete} =
             Notifications.dispatch_native_call_wake(
               intent.id,
               row.version,
               CommsWorkers.NativeCallWakeWorker
             )

    assert_received {:native_provider_effect, _}

    assert {:ok, _, _} =
             CommsCore.AudioCalls.with_join_authorized(
               account.conversation.id,
               call.id,
               current,
               fn _ -> {:ok, %{synthetic: true}} end
             )

    assert {:ok, _} =
             CommsCore.AudioCalls.revoke_for_sessions(
               account.tenant.id,
               [current.session_id],
               "owner_removed"
             )

    assert {:error, :native_push_unavailable} =
             Notifications.admit_native_call_wake(intent.id, current, fn _, _ ->
               flunk("Revoked current admission issued a wake credential")
             end)

    assert {:ok, _, _} =
             CommsCore.AudioCalls.with_join_authorized(
               account.conversation.id,
               call.id,
               current,
               fn _ -> {:ok, %{synthetic: true}} end
             )

    assert {:ok, %{owner: "conversation"}} =
             Notifications.admit_native_call_wake(intent.id, current, fn "conversation", _ ->
               {:ok, %{synthetic: true}}
             end)
  end

  test "event retries cannot extend the original wake horizon and duplicate jobs contain only opaque authority",
       %{account: account, subject: subject} do
    row = registration(subject)
    Process.put(:native_recipient_ids, [account.user.id])

    event = %CommsCore.Outbox.Event{
      id: Ecto.UUID.generate(),
      tenant_id: account.tenant.id,
      event_type: "call.started.v1",
      aggregate_type: "call",
      aggregate_id: Ecto.UUID.generate(),
      payload: %{conversation_id: account.conversation.id, caller: "Private caller"},
      inserted_at: DateTime.add(DateTime.utc_now(), -20, :second)
    }

    assert :ok = CommsCore.Notifications.NativePush.enqueue(event)
    first = Repo.get_by!(NativeCallWake, source_event_id: event.id)
    assert DateTime.diff(first.expires_at, DateTime.utc_now(), :second) <= 10
    assert :ok = CommsCore.Notifications.NativePush.enqueue(event)
    assert Repo.aggregate(NativeCallWake, :count) == 1
    job = Repo.get_by!(Oban.Job, worker: "CommsWorkers.NativeCallWakeWorker")
    assert job.args == %{"wake_id" => first.id, "registration_version" => row.version}
    refute inspect(job.args) =~ "Private caller"

    assert :ok =
             CommsCore.Notifications.NativePush.enqueue(%{
               event
               | id: Ecto.UUID.generate(),
                 inserted_at: DateTime.add(DateTime.utc_now(), -31, :second)
             })

    assert :ok =
             CommsCore.Notifications.NativePush.enqueue(%{
               event
               | id: Ecto.UUID.generate(),
                 inserted_at: nil
             })

    assert Repo.aggregate(NativeCallWake, :count) == 1
  end

  test "all retained states contribute owner-only fingerprints and rollback hazards", %{
    account: account,
    subject: subject
  } do
    row = registration(subject)
    intent = wake(row, "consumed")

    assert {:ok, _} =
             Notifications.revoke_native_push(
               %{channel: row.channel, expected_version: row.version},
               subject
             )

    assert Notifications.rollback_native_wake_hazards() == %{
             native_push_registrations: 1,
             native_call_wake_intents: 1
           }

    fragment = Notifications.release_tenant_fingerprint_fragment(Repo, account.tenant.id)
    assert fragment == %{native_push_registrations: [row.id], native_call_wakes: [intent.id]}

    assert Notifications.release_tenant_fingerprint_fragment(Repo, Ecto.UUID.generate()) == %{
             native_push_registrations: [],
             native_call_wakes: []
           }

    report = CommsCore.Release.InstantRoomFingerprint.fingerprint(Repo, account.tenant.slug)
    assert report.counts.native_push_registrations == 1 && report.counts.native_call_wakes == 1
    refute CommsCore.Release.InstantRoomFingerprint.format(report) =~ attrs().token
  end

  test "actual Telephony owner resolves a ringing assigned line only after explicit one-use admission",
       %{account: account, subject: subject} do
    Application.put_env(
      :comms_core,
      :native_call_wake_adapter,
      CommsIntegrations.NativePush.CallOwner
    )

    subject = Fixtures.step_up(account, subject)

    assert {:ok, _} =
             CommsCore.Telephony.provision(
               %{
                 phone_number: "+14155550100",
                 extension: "101",
                 user_id: account.user.id,
                 inbound_trunk_id: "ST_inbound",
                 outbound_trunk_id: "ST_outbound",
                 reason: "Synthetic native phone wake"
               },
               subject
             )

    row = registration(subject)

    assert {:ok, call, :applied} =
             CommsCore.Telephony.callback(
               %{
                 event_id: "native-incoming",
                 event_type: "participant_joined",
                 room: "kc_tel_inbound_native_incoming",
                 participant_identity: "sip_native_fixture",
                 participant_kind: :sip,
                 participant_sid: "PA_native_fixture",
                 provider_call_id: "SC_native_fixture",
                 trunk_id: "ST_inbound",
                 from_number: "+14155550200",
                 to_number: "+14155550100"
               },
               CommsIntegrations.Telephony.LiveKit
             )

    assert call.status == :ringing

    event = %CommsCore.Outbox.Event{
      id: Ecto.UUID.generate(),
      tenant_id: account.tenant.id,
      event_type: "telephony.call.updated",
      aggregate_type: "telephony_call",
      aggregate_id: call.id,
      payload: %{call_id: call.id, status: "ringing"},
      inserted_at: DateTime.utc_now()
    }

    assert :ok = CommsCore.Notifications.NativePush.enqueue(event)
    intent = Repo.get_by!(NativeCallWake, call_id: call.id)
    assert is_nil(Repo.get!(CommsCore.Telephony.Call, call.id).answer_session_id)

    assert {:ok, :complete} =
             Notifications.dispatch_native_call_wake(
               intent.id,
               row.version,
               CommsWorkers.NativeCallWakeWorker
             )

    assert_received {:native_provider_effect, _}
    assert is_nil(Repo.get!(CommsCore.Telephony.Call, call.id).answer_session_id)

    assert {:ok, %{owner: "telephony", data: admitted}} =
             Notifications.admit_native_call_wake(intent.id, subject, fn "telephony",
                                                                         %CommsCore.Telephony.CredentialRequest{} ->
               {:ok, %{synthetic: true}}
             end)

    assert admitted.active_on_this_device
    assert Repo.get!(CommsCore.Telephony.Call, call.id).answer_session_id == account.session.id

    assert {:error, :native_push_unavailable} =
             Notifications.admit_native_call_wake(intent.id, subject, fn _, _ ->
               flunk("Native telephony replay issued another credential")
             end)
  end

  test "reconciliation durably pages beyond one hundred registrations and preserves current authority",
       %{account: account, subject: subject} do
    row = registration(subject)

    for index <- 1..100 do
      device =
        Repo.insert!(
          CommsCore.Accounts.Device.changeset(
            %CommsCore.Accounts.Device{},
            %{
              tenant_id: row.tenant_id,
              user_id: row.user_id,
              name: "Synthetic stale native device",
              platform: "ios"
            }
          )
        )

      data = row |> Map.from_struct() |> Map.drop([:id, :__meta__, :inserted_at, :updated_at])
      # Retained devices whose origin Session belongs to another device are
      # not current authority, even with otherwise well-formed private rows.
      data =
        Map.merge(data, %{
          device_id: device.id,
          installation_id: Ecto.UUID.generate(),
          token_hash: :crypto.hash(:sha256, "native-fixture-#{index}")
        })

      Repo.insert!(NativePushRegistration.changeset(%NativePushRegistration{}, data))
    end

    ids = Repo.all(from(r in NativePushRegistration, order_by: r.id, select: r.id))
    assert length(ids) == 101
    assert :ok = Notifications.reconcile_native_push(CommsWorkers.NativePushReconcilerWorker, %{})
    child = Repo.get_by!(Oban.Job, worker: "CommsWorkers.NativePushReconcilerWorker")
    assert child.args == %{"after_id" => Enum.at(ids, 99)}
    assert :ok = CommsWorkers.NativePushReconcilerWorker.perform(child)

    assert Repo.aggregate(from(r in NativePushRegistration, where: r.status == "active"), :count) ==
             1

    assert Repo.get!(NativePushRegistration, row.id).status == "active"

    assert Repo.aggregate(
             from(r in NativePushRegistration, where: not is_nil(r.ciphertext)),
             :count
           ) == 1

    assert Notifications.release_tenant_fingerprint_fragment(Repo, account.tenant.id).native_push_registrations
           |> length() == 101
  end

  defp authenticate_owner(account) do
    suffix = account.tenant.slug |> String.split("-") |> List.last()
    authenticate(account, account.user.email, "correct-horse-battery-#{suffix}")
  end

  defp authenticate_member(account, member) do
    [local, _] = String.split(member.email, "@", parts: 2)
    suffix = String.replace_prefix(local, "member-", "")
    authenticate(account, member.email, "correct-horse-battery-#{suffix}")
  end

  defp authenticate(account, email, password) do
    {:ok, authentication} =
      Accounts.authenticate_view(account.tenant.slug, email, password, %{
        name: "Synthetic replacement native device",
        platform: "ios"
      })

    {:ok, context} = Accounts.access_context(authentication.session_id)
    context.subject
  end

  defp attrs,
    do: %{
      platform: "ios",
      channel: "apns_voip",
      application_id: "com.synthetic.native",
      environment: "sandbox",
      token: String.duplicate("a", 64),
      installation_id: "00000000-0000-4000-8000-000000000001",
      expected_version: 0
    }

  defp registration(subject) do
    {:ok, %{registration: view}} = Notifications.register_native_push(attrs(), subject)
    Repo.get!(NativePushRegistration, view.id)
  end

  defp wake(row, status \\ "pending", seconds \\ 25) do
    %NativeCallWake{}
    |> NativeCallWake.changeset(%{
      tenant_id: row.tenant_id,
      user_id: row.user_id,
      device_id: row.device_id,
      session_id: row.session_id,
      registration_id: row.id,
      registration_version: row.version,
      user_version: row.user_version,
      owner: "conversation",
      call_id: Ecto.UUID.generate(),
      conversation_id: Ecto.UUID.generate(),
      source_event_id: Ecto.UUID.generate(),
      status: status,
      expires_at: DateTime.add(DateTime.utc_now(), seconds, :second)
    })
    |> Repo.insert!()
  end

  defp context(row),
    do: %{
      tenant_id: row.tenant_id,
      registration_id: row.id,
      version: row.version,
      channel: row.channel,
      application_id: row.application_id,
      environment: row.environment
    }
end
