defmodule CommsCore.TelephonyTest do
  use CommsCore.DataCase, async: false
  @moduletag :integration
  @moduletag :call
  alias CommsCore.{Accounts, Administration, Telephony}
  alias CommsCore.Accounts.{Session, User}

  alias CommsCore.Telephony.{
    Call,
    CredentialRequest,
    Number,
    ProviderCommand,
    ProviderEvent,
    RoomTombstone
  }

  alias CommsIntegrations.Telephony.LiveKit
  alias CommsTestSupport.Fixtures
  alias CommsWorkers.{TelephonyDispatchWorker, TelephonyExpiryWorker}

  setup do
    previous = Application.get_env(:comms_core, :telephony_callback_adapter)
    Application.put_env(:comms_core, :telephony_callback_adapter, LiveKit)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:comms_core, :telephony_callback_adapter, previous),
        else: Application.delete_env(:comms_core, :telephony_callback_adapter)
    end)

    :ok
  end

  test "provisioning requires a persisted owner, recent step-up, same-tenant active human and unique DID" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:error, :step_up_required} = Telephony.provision(assignment(account), subject)
    subject = Fixtures.step_up(account)

    assert {:error, :reason_required} =
             Telephony.provision(Map.put(assignment(account), :reason, " "), subject)

    other = Fixtures.account_fixture()

    assert {:error, :forbidden} =
             Telephony.provision(Map.put(assignment(account), :user_id, other.user.id), subject)

    assert {:ok, config} = Telephony.provision(assignment(account), subject)
    assert config.configured
    assert config.number.extension == "101"
    assert {:ok, %{number: own}} = Telephony.config(subject)
    refute Map.has_key?(own, :inbound_trunk_id)
    other_subject = Fixtures.step_up(other)

    assert {:error, %CommsCore.ValidationError{}} =
             Telephony.provision(assignment(other), other_subject)

    assert Repo.aggregate(Number, :count) == 1
    assert {:ok, _call, :created} = Telephony.start_outbound(outbound(), subject)
    assert {:error, :active_call_conflict} = Telephony.provision(assignment(account), subject)
  end

  test "outbound idempotency is user-scoped, conflicts fail closed and media join precedes dialing" do
    {account, subject} = ready()
    assert {:ok, call, :created} = Telephony.start_outbound(outbound(), subject)
    assert {:ok, replay, :replayed} = Telephony.start_outbound(outbound(), subject)
    assert replay.id == call.id

    assert {:error, :idempotency_conflict} =
             Telephony.start_outbound(Map.put(outbound(), :destination, "+14155550300"), subject)

    assert {:error, :busy} =
             Telephony.start_outbound(Map.put(outbound(), :idempotency_key, "other"), subject)

    assert {:ok, {:not_ready, _}} = Telephony.claim_dispatch(call.id, TelephonyDispatchWorker)
    assert {:ok, _view, %{credential: "issued"}} = Telephony.join(call.id, subject, issuer())
    stored = Repo.get!(Call, call.id)
    assert {:ok, _, :applied} = Telephony.callback(app_joined(stored), LiveKit)

    assert {:ok, %ProviderCommand{reconcile: false} = command} =
             Telephony.claim_dispatch(call.id, TelephonyDispatchWorker)

    assert command.from_number == "+14155550100"

    assert {:ok, %ProviderCommand{reconcile: true}} =
             Telephony.claim_dispatch(call.id, TelephonyDispatchWorker)

    assert {:ok, :answered} =
             Telephony.complete_dispatch(
               call.id,
               {:ok, %{provider_call_id: "SC_outbound", state: :answered}},
               TelephonyDispatchWorker
             )

    assert {:ok, connected} = Telephony.get_call(call.id, subject)
    assert connected.status == :answered
    assert connected.answered_at
    assert connected.active_on_this_device
    refute Map.has_key?(connected, :provider_room)
    foreign = Fixtures.account_fixture()
    assert {:error, :not_found} = Telephony.get_call(call.id, Fixtures.subject(foreign))
    assert {:ok, %{calls: []}} = Telephony.list_calls(Fixtures.subject(foreign))
    assert account.user.id == stored.user_id
  end

  test "inbound answer reserves one device and connected time requires actual SIP active" do
    {account, subject} = ready()
    event = incoming()
    assert {:ok, call, :applied} = Telephony.callback(event, LiveKit)
    assert call.status == :ringing
    assert call.connected_seconds == 0
    assert {:ok, visible} = Telephony.get_call(call.id, subject)
    assert visible.can_answer
    assert {:ok, reserved, %{credential: "issued"}} = Telephony.answer(call.id, subject, issuer())
    assert reserved.status == :ringing
    assert reserved.answered_at == nil
    assert reserved.active_on_this_device
    second_subject = second_device(account)
    assert {:error, :answered_elsewhere} = Telephony.answer(call.id, second_subject, issuer())
    assert {:error, :answered_elsewhere} = Telephony.join(call.id, second_subject, issuer())
    stored = Repo.get!(Call, call.id)
    assert {:ok, awaiting, :applied} = Telephony.callback(app_joined(stored), LiveKit)
    assert awaiting.answered_at == nil

    assert {:ok, %ProviderCommand{direction: :inbound, reconcile: true}} =
             Telephony.claim_dispatch(call.id, TelephonyDispatchWorker)

    assert {:ok, :pending} =
             Telephony.complete_dispatch(call.id, :pending, TelephonyDispatchWorker)

    assert {:ok, still_ringing} = Telephony.get_call(call.id, subject)
    assert still_ringing.status == :ringing

    assert {:ok, :answered} =
             Telephony.complete_dispatch(
               call.id,
               {:ok, %{provider_call_id: "SC_inbound", state: :answered}},
               TelephonyDispatchWorker
             )

    assert {:ok, ended} = Telephony.end_call(call.id, subject)
    assert ended.status == :ended
    assert ended.answered_at
    assert ended.connected_seconds >= 0
    assert {:ok, _, :duplicate} = Telephony.callback(event, LiveKit)

    assert {:ok, late, :ignored} =
             Telephony.callback(Map.put(event, :event_id, "late_join"), LiveKit)

    assert late.status == :ended
    assert Repo.aggregate(ProviderEvent, :count) == 3
  end

  test "credential issuer failure rolls back the incoming first-device claim" do
    {_account, subject} = ready()
    assert {:ok, call, :applied} = Telephony.callback(incoming(), LiveKit)

    assert {:error, :issuer_failed} =
             Telephony.answer(call.id, subject, fn _ -> {:error, :issuer_failed} end)

    stored = Repo.get!(Call, call.id)
    assert stored.answer_session_id == nil
    assert {:ok, _view, _credential} = Telephony.answer(call.id, subject, issuer())
  end

  test "left-before-join remains terminal, wrong trunk and browser SIP attributes cannot admit a call" do
    {_account, _subject} = ready()

    assert {:ok, nil, :ignored} =
             Telephony.callback(Map.put(incoming(), :trunk_id, "ST_wrong"), LiveKit)

    assert {:ok, nil, :ignored} =
             Telephony.callback(Map.put(incoming(), :participant_kind, :standard), LiveKit)

    assert {:ok, nil, :ignored} =
             Telephony.callback(Map.put(incoming(), :room, "existing_conversation_room"), LiveKit)

    assert {:error, :forbidden} = Telephony.callback(incoming(), __MODULE__)

    assert {:ok, left, :ignored} =
             Telephony.callback(
               %{incoming() | event_type: "participant_left", event_id: "left_first"},
               LiveKit
             )

    assert left.status == :no_answer
    assert left.answered_at == nil
    assert {:ok, late, :ignored} = Telephony.callback(incoming(), LiveKit)
    assert late.id == left.id
    assert late.status == :no_answer
    assert Repo.aggregate(Call, :count) == 1
  end

  test "missed and declined outcomes are durable, no-answer history uses stable cursor" do
    {_account, subject} = ready()
    assert {:ok, missed, :applied} = Telephony.callback(incoming(), LiveKit)
    age_to_expiry(missed.id)
    assert {:ok, :expired} = Telephony.expire(missed.id, TelephonyExpiryWorker)

    assert {:ok, declined, :applied} =
             Telephony.callback(
               %{
                 incoming()
                 | room: "kc_tel_inbound_second",
                   event_id: "second",
                   provider_call_id: "SC_second"
               },
               LiveKit
             )

    assert {:ok, outcome} = Telephony.reject(declined.id, subject)
    assert outcome.status == :declined

    assert {:ok, %{calls: [first], has_more: true, next_cursor: cursor}} =
             Telephony.list_calls(subject, %{limit: 1})

    assert first.id == declined.id

    assert {:ok, %{calls: [second], has_more: false}} =
             Telephony.list_calls(subject, %{limit: 1, cursor: cursor})

    assert second.id == missed.id
    assert {:ok, %{calls: [only_missed]}} = Telephony.list_calls(subject, %{scope: :missed})
    assert only_missed.status == :no_answer
    assert {:error, :invalid_cursor} = Telephony.list_calls(subject, %{cursor: "broken"})
    assert {:error, :invalid_call_scope} = Telephony.list_calls(subject, %{scope: "anytenant"})
  end

  test "history search filters retained records before pagination and preserves user isolation" do
    {account, subject} = ready()
    %{user: colleague} = Fixtures.user_fixture(account)
    number = Repo.get_by!(Number, tenant_id: account.tenant.id)

    calls =
      for {user_id, direction, started_at} <- [
            {account.user.id, :inbound, ~U[2026-10-01 00:00:00.000000Z]},
            {account.user.id, :inbound, ~U[2026-10-01 23:59:59.999999Z]},
            {account.user.id, :outbound, ~U[2026-10-01 12:00:00.000000Z]},
            {account.user.id, :inbound, ~U[2026-10-02 00:00:00.000000Z]},
            {colleague.id, :inbound, ~U[2026-10-01 23:59:59.999999Z]}
          ] do
        %Call{}
        |> Call.changeset(%{
          tenant_id: account.tenant.id,
          user_id: user_id,
          number_id: number.id,
          direction: direction,
          status: :no_answer,
          end_reason: "no_answer",
          from_number: if(direction == :inbound, do: "+14155550901", else: number.phone_number),
          to_number: if(direction == :inbound, do: number.phone_number, else: "+14155550901"),
          extension: number.extension,
          inbound_trunk_id: number.inbound_trunk_id,
          outbound_trunk_id: number.outbound_trunk_id,
          provider_room: "synthetic_history_" <> Ecto.UUID.generate(),
          provider_identity: "synthetic-caller",
          started_at: started_at,
          ended_at: DateTime.add(started_at, 30, :second),
          expires_at: DateTime.add(started_at, 60, :second)
        })
        |> Repo.insert!()
      end

    filters = %{
      q: "+1 (415) 555-0901",
      direction: "inbound",
      from: "2026-10-01",
      to: "2026-10-01",
      limit: 1
    }

    assert {:ok, %{calls: [newer], has_more: true, next_cursor: cursor}} =
             Telephony.list_calls(subject, filters)

    assert newer.id == Enum.at(calls, 1).id

    assert {:ok, %{calls: [older], has_more: false}} =
             Telephony.list_calls(subject, Map.put(filters, :cursor, cursor))

    assert older.id == hd(calls).id

    assert {:ok, %{calls: [outgoing]}} =
             Telephony.list_calls(subject, %{filters | direction: "outbound"})

    assert outgoing.id == Enum.at(calls, 2).id
    assert {:ok, %{calls: []}} = Telephony.list_calls(subject, %{q: "%"})

    assert {:ok, %{calls: []}} =
             Telephony.list_calls(Fixtures.subject(Fixtures.account_fixture()), filters)

    for filters <- [
          %{q: String.duplicate("1", 81)},
          %{direction: "sideways"},
          %{from: "bad"},
          %{from: "2026-10-02", to: "2026-10-01"}
        ] do
      assert {:error, :invalid_phone_history_filters} = Telephony.list_calls(subject, filters)
    end
  end

  test "audio policy and revoked sessions block tokens, callbacks and telephone dispatch" do
    {account, subject} = ready()
    assert {:ok, call, :created} = Telephony.start_outbound(outbound(), subject)
    assert {:ok, _, _} = Telephony.join(call.id, subject, issuer())
    stored = Repo.get!(Call, call.id)
    account.session |> Session.changeset(%{revoked_at: DateTime.utc_now()}) |> Repo.update!()
    assert {:error, :forbidden} = Telephony.join(call.id, subject, issuer())
    assert {:ok, failed, :applied} = Telephony.callback(app_joined(stored), LiveKit)
    assert failed.status == :failed
    assert failed.end_reason == "access_revoked"
    assert {:ok, :already_terminal} = Telephony.claim_dispatch(call.id, TelephonyDispatchWorker)
    other = Fixtures.account_fixture()
    other_subject = Fixtures.step_up(other)

    assert {:ok, _} =
             Administration.update_tenant_settings(
               %{allow_audio_calls: false, reason: "Disable phone calls", version: 1},
               other_subject
             )

    assert {:error, :audio_calls_disabled} = Telephony.start_outbound(outbound(), other_subject)
  end

  test "tokens and natural connected-call expiry cannot outlive the session authority" do
    {account, subject} = ready()
    deadline = DateTime.add(DateTime.utc_now(), 20, :second) |> DateTime.truncate(:microsecond)
    account.session |> Session.changeset(%{expires_at: deadline}) |> Repo.update!()
    assert {:ok, call, :created} = Telephony.start_outbound(outbound(), subject)

    assert {:ok, _, %{credential: "issued"}} =
             Telephony.join(call.id, subject, fn request ->
               assert %CredentialRequest{authorization_expires_at: ^deadline} = request
               {:ok, %{credential: "issued"}}
             end)

    stored = Repo.get!(Call, call.id)
    assert stored.expires_at == deadline
    assert {:ok, _, :applied} = Telephony.callback(app_joined(stored), LiveKit)

    assert {:ok, :answered} =
             Telephony.complete_dispatch(
               call.id,
               {:ok, %{provider_call_id: "SC_bound", state: :answered}},
               TelephonyDispatchWorker
             )

    assert Repo.get!(Call, call.id).expires_at == deadline
  end

  test "administrator own-line config never exposes another assigned user's line" do
    {account, subject} = ready()
    member = Fixtures.user_fixture(account).user

    assert {:ok, _} =
             Telephony.provision(Map.put(assignment(account), :user_id, member.id), subject)

    assert {:ok, %{configured: false, number: nil, can_manage: true}} = Telephony.config(subject)
    assert {:ok, %{configured: true, number: %{user_id: id}}} = Telephony.admin_config(subject)
    assert id == member.id
    account.user |> User.changeset(%{role: :member}) |> Repo.update!()
    assert {:error, :forbidden} = Telephony.admin_config(subject)
  end

  test "delayed expiry processing never authorizes a late dial or answer" do
    {_account, subject} = ready()
    assert {:ok, call, :created} = Telephony.start_outbound(outbound(), subject)
    assert {:ok, _, _} = Telephony.join(call.id, subject, issuer())
    assert {:ok, _, :applied} = Telephony.callback(app_joined(Repo.get!(Call, call.id)), LiveKit)
    age_to_expiry(call.id)
    assert {:ok, :already_terminal} = Telephony.claim_dispatch(call.id, TelephonyDispatchWorker)
    assert Repo.get!(Call, call.id).status == :no_answer

    assert {:ok, :already_terminal} =
             Telephony.complete_dispatch(
               call.id,
               {:ok, %{state: :answered, provider_call_id: "late"}},
               TelephonyDispatchWorker
             )

    assert Repo.get!(Call, call.id).answered_at == nil
    assert Repo.get!(Call, call.id).provider_call_id == "late"
    assert Repo.get!(Call, call.id).status == :no_answer
  end

  test "provider dispatch can report an answer only with a matching connected leg" do
    {_account, subject} = ready()

    invalid_results = [
      %{state: :ringing, provider_call_id: "SC_ringing"},
      %{state: :answered},
      %{state: :answered, provider_call_id: ""},
      %{state: :answered, provider_call_id: "SC_wrong_room", provider_room: "another_room"},
      %{
        state: :answered,
        provider_call_id: "SC_wrong_identity",
        provider_identity: "another_identity"
      },
      :answered
    ]

    for {result, index} <- Enum.with_index(invalid_results) do
      assert {:ok, call, :created} =
               Telephony.start_outbound(
                 Map.put(outbound(), :idempotency_key, "invalid_outcome_#{index}"),
                 subject
               )

      assert {:ok, _, _} = Telephony.join(call.id, subject, issuer())

      assert {:ok, _, :applied} =
               Telephony.callback(app_joined(Repo.get!(Call, call.id)), LiveKit)

      assert {:ok, :failed} =
               Telephony.complete_dispatch(call.id, {:ok, result}, TelephonyDispatchWorker)

      stored = Repo.get!(Call, call.id)
      assert stored.status == :failed
      assert stored.answered_at == nil
      assert stored.provider_call_id == nil
      assert stored.end_reason == "provider_invalid_outcome"
    end
  end

  test "answered media permits only a bounded same-device reconnect and SIP hangup ends immediately" do
    {_account, subject} = ready()
    assert {:ok, call, :created} = Telephony.start_outbound(outbound(), subject)
    assert {:ok, _, _} = Telephony.join(call.id, subject, issuer())
    stored = Repo.get!(Call, call.id)
    assert {:ok, _, :applied} = Telephony.callback(app_joined(stored), LiveKit)

    assert {:ok, :answered} =
             Telephony.complete_dispatch(
               call.id,
               {:ok, %{state: :answered, provider_call_id: "SC_connected"}},
               TelephonyDispatchWorker
             )

    left = %{app_joined(stored) | event_id: "app_left", event_type: "participant_left"}
    assert {:ok, disconnected, :applied} = Telephony.callback(left, LiveKit)
    assert disconnected.status == :answered
    assert Repo.get!(Call, call.id).app_reconnect_deadline
    assert {:ok, _, _} = Telephony.join(call.id, subject, issuer())

    rejoined = %{
      app_joined(stored)
      | event_id: "app_rejoined",
        participant_sid: "PA_rejoined_" <> call.id
    }

    assert {:ok, _, :applied} = Telephony.callback(rejoined, LiveKit)

    assert Repo.get!(Call, call.id).app_reconnect_deadline == nil

    assert {:ok, _, :applied} =
             Telephony.callback(
               %{
                 left
                 | event_id: "app_left_again",
                   participant_sid: rejoined.participant_sid,
                   occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
               },
               LiveKit
             )

    assert Repo.get!(Call, call.id).app_reconnect_deadline

    deadline = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:microsecond)

    from(c in Call, where: c.id == ^call.id)
    |> Repo.update_all(set: [app_reconnect_deadline: deadline])

    assert {:error, :call_ended} = Telephony.join(call.id, subject, issuer())
    assert {:ok, :expired} = Telephony.expire(call.id, TelephonyExpiryWorker)
    assert Repo.get!(Call, call.id).end_reason == "app_reconnect_timeout"

    assert {:ok, next_call, :created} =
             Telephony.start_outbound(Map.put(outbound(), :idempotency_key, "next"), subject)

    assert {:ok, _, _} = Telephony.join(next_call.id, subject, issuer())
    next_stored = Repo.get!(Call, next_call.id)
    assert {:ok, _, :applied} = Telephony.callback(app_joined(next_stored), LiveKit)

    assert {:ok, :answered} =
             Telephony.complete_dispatch(
               next_call.id,
               {:ok, %{state: :answered, provider_call_id: "SC_next"}},
               TelephonyDispatchWorker
             )

    assert {:ok, ended, :applied} =
             Telephony.callback(
               %{
                 event_id: "sip_left",
                 event_type: "participant_left",
                 room: next_stored.provider_room,
                 participant_identity: next_stored.provider_identity
               },
               LiveKit
             )

    assert ended.status == :ended
    assert Repo.get!(Call, next_call.id).app_reconnect_deadline == nil
  end

  test "finished-before-attribution creates a hashed bounded tombstone and late join cannot ring" do
    {_account, _subject} = ready()

    assert {:ok, nil, :ignored} =
             Telephony.callback(
               %{event_id: "finished_first", event_type: "room_finished", room: incoming().room},
               LiveKit
             )

    assert Repo.aggregate(RoomTombstone, :count) == 1
    tombstone = Repo.one(RoomTombstone)
    refute tombstone.room_hash == incoming().room
    assert String.length(tombstone.room_hash) == 64
    assert {:ok, terminal, :ignored} = Telephony.callback(incoming(), LiveKit)
    assert terminal.status == :no_answer
    assert terminal.answered_at == nil
  end

  test "reordered old application events cannot cancel reconnect grace or disconnect a new epoch" do
    {_account, subject} = ready()
    assert {:ok, call, :created} = Telephony.start_outbound(outbound(), subject)
    assert {:ok, _, _} = Telephony.join(call.id, subject, issuer())
    stored = Repo.get!(Call, call.id)
    initial_time = DateTime.add(DateTime.utc_now(), -10, :second) |> DateTime.truncate(:second)
    original = %{app_joined(stored) | occurred_at: initial_time}
    assert {:ok, _, :applied} = Telephony.callback(original, LiveKit)

    assert {:ok, :answered} =
             Telephony.complete_dispatch(
               call.id,
               {:ok, %{state: :answered, provider_call_id: "SC_ordered"}},
               TelephonyDispatchWorker
             )

    left = %{
      original
      | event_id: "ordered_left",
        event_type: "participant_left",
        occurred_at: DateTime.add(initial_time, 1, :second)
    }

    assert {:ok, _, :applied} = Telephony.callback(left, LiveKit)
    deadline = Repo.get!(Call, call.id).app_reconnect_deadline
    assert deadline

    assert {:ok, _, :applied} =
             Telephony.callback(%{original | event_id: "late_original_join"}, LiveKit)

    assert Repo.get!(Call, call.id).app_reconnect_deadline == deadline
    # Provider createdAt has second precision. A new SID after a left in the
    # same second still identifies a distinct connection; an old SID does not.
    rejoined = %{
      original
      | event_id: "ordered_rejoin",
        participant_sid: "PA_new_epoch",
        occurred_at: left.occurred_at
    }

    assert {:ok, _, :applied} = Telephony.callback(rejoined, LiveKit)
    assert Repo.get!(Call, call.id).app_reconnect_deadline == nil
    assert {:ok, _, :applied} = Telephony.callback(%{left | event_id: "late_old_left"}, LiveKit)
    current = Repo.get!(Call, call.id)
    assert current.status == :answered
    assert current.app_reconnect_deadline == nil
    assert current.app_provider_sid == "PA_new_epoch"
  end

  test "provider admission disabled still records and tears down an owned incoming leg" do
    {_account, subject} = ready()

    assert {:ok, denied, :ignored} =
             Telephony.callback(Map.put(incoming(), :admission_enabled, false), LiveKit)

    assert denied.status == :failed
    assert {:ok, view} = Telephony.get_call(denied.id, subject)
    refute view.can_answer

    assert Repo.exists?(
             from(j in Oban.Job,
               where:
                 fragment("?->>'call_id' = ?", j.args, ^denied.id) and
                   j.worker == "CommsWorkers.TelephonyCleanupWorker"
             )
           )
  end

  test "same-second epoch replacement converges for either join and leave arrival order" do
    {_account, subject} = ready()

    for ordering <- [:left_before_join, :join_before_left, :replacement_left_before_old_left] do
      assert {:ok, call, :created} =
               Telephony.start_outbound(
                 Map.put(outbound(), :idempotency_key, "epoch_order_#{ordering}"),
                 subject
               )

      assert {:ok, _, _} = Telephony.join(call.id, subject, issuer())
      stored = Repo.get!(Call, call.id)
      timestamp = DateTime.add(DateTime.utc_now(), -10, :second) |> DateTime.truncate(:second)
      original = %{app_joined(stored) | occurred_at: timestamp}
      assert {:ok, _, :applied} = Telephony.callback(original, LiveKit)

      assert {:ok, :answered} =
               Telephony.complete_dispatch(
                 call.id,
                 {:ok, %{state: :answered, provider_call_id: "SC_epoch_#{ordering}"}},
                 TelephonyDispatchWorker
               )

      replacement = %{
        original
        | event_id: "replacement_" <> call.id,
          participant_sid: "PA_replacement_" <> call.id
      }

      original_left = %{
        original
        | event_id: "original_left_" <> call.id,
          event_type: "participant_left"
      }

      if ordering == :left_before_join do
        assert {:ok, _, :applied} = Telephony.callback(original_left, LiveKit)
        assert {:ok, _, :applied} = Telephony.callback(replacement, LiveKit)
      else
        assert {:ok, _, :applied} = Telephony.callback(replacement, LiveKit)
        assert Repo.get!(Call, call.id).app_pending_sid == replacement.participant_sid

        if ordering == :replacement_left_before_old_left do
          assert {:ok, _, :applied} =
                   Telephony.callback(
                     %{
                       replacement
                       | event_id: "replacement_left_" <> call.id,
                         event_type: "participant_left"
                     },
                     LiveKit
                   )
        end

        assert {:ok, _, :applied} = Telephony.callback(original_left, LiveKit)
      end

      assert {:ok, _, :applied} =
               Telephony.callback(
                 %{original | event_id: "stale_original_join_" <> call.id},
                 LiveKit
               )

      current = Repo.get!(Call, call.id)
      assert current.status == :answered

      if ordering == :replacement_left_before_old_left do
        assert current.app_reconnect_deadline

        assert {:ok, _, :applied} =
                 Telephony.callback(
                   %{replacement | event_id: "stale_replacement_join_" <> call.id},
                   LiveKit
                 )

        assert Repo.get!(Call, call.id).app_reconnect_deadline == current.app_reconnect_deadline
      else
        assert current.app_provider_sid == replacement.participant_sid
        assert current.app_pending_sid == nil
        assert current.app_reconnect_deadline == nil

        assert {:ok, _, :applied} =
                 Telephony.callback(
                   %{original_left | event_id: "stale_original_left_" <> call.id},
                   LiveKit
                 )

        assert Repo.get!(Call, call.id).app_reconnect_deadline == nil
      end

      assert {:ok, _} = Telephony.end_call(call.id, subject)
    end
  end

  test "an accepted inbound app with no observed SIP answer is unconfirmed rather than missed" do
    {_account, subject} = ready()

    for terminal <- [:sip_left, :room_finished, :worker_ended, :expiry] do
      event = %{
        incoming()
        | event_id: "unconfirmed_#{terminal}",
          room: "kc_tel_inbound_unconfirmed_#{terminal}"
      }

      assert {:ok, call, :applied} = Telephony.callback(event, LiveKit)
      assert {:ok, _, _} = Telephony.answer(call.id, subject, issuer())
      stored = Repo.get!(Call, call.id)
      assert {:ok, _, :applied} = Telephony.callback(app_joined(stored), LiveKit)
      assert Repo.get!(Call, call.id).answered_at == nil

      case terminal do
        :sip_left ->
          assert {:ok, _, :applied} =
                   Telephony.callback(
                     %{event | event_id: "unconfirmed_left", event_type: "participant_left"},
                     LiveKit
                   )

        :room_finished ->
          assert {:ok, _, :applied} =
                   Telephony.callback(
                     %{event | event_id: "unconfirmed_room", event_type: "room_finished"},
                     LiveKit
                   )

        :worker_ended ->
          assert {:ok, :failed} =
                   Telephony.complete_dispatch(
                     call.id,
                     {:error, :no_answer},
                     TelephonyDispatchWorker
                   )

        :expiry ->
          age_to_expiry(call.id)
          assert {:ok, :expired} = Telephony.expire(call.id, TelephonyExpiryWorker)
      end

      assert {:ok, outcome} = Telephony.get_call(call.id, subject)
      assert outcome.status == :failed
      assert outcome.end_reason == "answer_unconfirmed"
      assert outcome.answered_at == nil
      assert outcome.connected_seconds == 0
    end

    assert {:ok, %{calls: []}} = Telephony.list_calls(subject, %{scope: :missed})
  end

  test "mapped inbound SIP calls receive durable teardown when assignee or audio policy is inactive" do
    {account, subject} = ready()
    account.user |> User.changeset(%{status: :suspended}) |> Repo.update!()
    assert {:ok, rejected, :ignored} = Telephony.callback(incoming(), LiveKit)
    assert rejected.status == :failed

    assert Repo.exists?(
             from(j in Oban.Job,
               where:
                 fragment("?->>'call_id' = ?", j.args, ^rejected.id) and
                   j.worker == "CommsWorkers.TelephonyCleanupWorker"
             )
           )

    Repo.get!(User, account.user.id) |> User.changeset(%{status: :active}) |> Repo.update!()

    assert {:ok, _} =
             Administration.update_tenant_settings(
               %{version: 1, allow_audio_calls: false},
               subject
             )

    assert {:ok, denied, :ignored} =
             Telephony.callback(
               %{incoming() | room: "kc_tel_inbound_disabled", event_id: "disabled_event"},
               LiveKit
             )

    assert denied.status == :failed
  end

  defp ready do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    assert {:ok, _} = Telephony.provision(assignment(account), subject)
    {account, subject}
  end

  defp assignment(account),
    do: %{
      phone_number: "+14155550100",
      extension: "101",
      user_id: account.user.id,
      inbound_trunk_id: "ST_inbound",
      outbound_trunk_id: "ST_outbound",
      reason: "Synthetic phone provisioning"
    }

  defp outbound, do: %{destination: "+14155550200", idempotency_key: "stable-outbound-key"}

  defp incoming,
    do: %{
      event_id: "incoming_event",
      event_type: "participant_joined",
      room: "kc_tel_inbound_fixture",
      participant_identity: "sip_fixture_identity",
      participant_kind: :sip,
      participant_sid: "PA_sip_fixture",
      provider_call_id: "SC_inbound",
      trunk_id: "ST_inbound",
      from_number: "+14155550200",
      to_number: "+14155550100"
    }

  defp app_joined(call),
    do: %{
      event_id: "app_joined_" <> call.id,
      event_type: "participant_joined",
      room: call.provider_room,
      participant_identity: call.app_identity,
      participant_kind: :standard,
      participant_sid: "PA_app_" <> call.id,
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

  defp issuer, do: fn %CredentialRequest{} -> {:ok, %{credential: "issued"}} end

  defp second_device(account) do
    suffix = account.tenant.slug |> String.split("-") |> List.last()

    {:ok, authentication} =
      Accounts.authenticate_view(
        account.tenant.slug,
        account.user.email,
        "correct-horse-battery-#{suffix}",
        %{name: "Second browser", platform: "test"}
      )

    {:ok, context} = Accounts.access_context(authentication.session_id)
    context.subject
  end

  defp age_to_expiry(id) do
    timestamp = DateTime.add(DateTime.utc_now(), -100, :second) |> DateTime.truncate(:microsecond)

    from(c in Call, where: c.id == ^id)
    |> Repo.update_all(
      set: [started_at: timestamp, expires_at: DateTime.add(timestamp, 60, :second)]
    )
  end
end
