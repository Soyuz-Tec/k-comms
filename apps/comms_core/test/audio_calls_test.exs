defmodule CommsCore.AudioCallsTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts
  alias CommsCore.Accounts.Session
  alias CommsCore.Administration.Tenant
  alias CommsCore.Administration
  alias CommsCore.Administration.TenantSettings
  alias CommsCore.AudioCalls
  alias CommsCore.AudioCalls.{AudioCall, AudioCallParticipant}
  alias CommsCore.Audit
  alias CommsCore.Conversations
  alias CommsCore.Conversations.Membership
  alias CommsCore.Events.OutboxEvent
  alias CommsTestSupport.Fixtures

  test "start is idempotent, durable, audited, and bounded to eight hours" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, first, :created} = AudioCalls.start(account.conversation.id, subject)
    assert {:ok, replay, :existing} = AudioCalls.start(account.conversation.id, subject)
    assert replay.id == first.id
    assert first.status == :active
    assert first.media_kind == :audio
    assert DateTime.diff(first.expires_at, first.started_at, :second) == 28_800
    assert Repo.aggregate(AudioCall, :count) == 1

    expiry_job =
      Repo.get_by!(Oban.Job,
        worker: "CommsWorkers.AudioCallExpiryWorker",
        args: %{"call_id" => first.id, "tenant_id" => first.tenant_id}
      )

    assert expiry_job.state == "scheduled"
    assert expiry_job.queue == "media"
    assert DateTime.compare(expiry_job.scheduled_at, first.expires_at) == :eq

    assert Repo.aggregate(
             from(job in Oban.Job,
               where:
                 job.worker == "CommsWorkers.AudioCallExpiryWorker" and
                   fragment("?->>'call_id'", job.args) == ^first.id
             ),
             :count
           ) == 1

    assert Audit.get_by!(%{
             tenant_id: account.tenant.id,
             resource_id: first.id,
             action: "audio_call.start"
           })

    assert Repo.get_by!(OutboxEvent,
             aggregate_id: first.id,
             event_type: "audio_call.started.v1"
           )

    started_event =
      Repo.get_by!(OutboxEvent,
        aggregate_id: first.id,
        event_type: "call.started.v1"
      )

    assert started_event.payload["media_kind"] == "audio"
  end

  test "video start is idempotent and conflicts with an active audio call" do
    video = Fixtures.account_fixture()
    video_subject = Fixtures.subject(video)

    assert {:ok, first, :created} =
             AudioCalls.start_with_kind(video.conversation.id, video_subject, :video)

    assert {:ok, replay, :existing} =
             AudioCalls.start(video.conversation.id, video_subject, :video)

    assert first.id == replay.id
    assert first.media_kind == :video

    assert {:error, :call_media_kind_conflict} =
             AudioCalls.start(video.conversation.id, video_subject)

    assert Repo.aggregate(AudioCall, :count) == 1

    assert {:ok, ended} =
             AudioCalls.end_call(
               video.conversation.id,
               first.id,
               %{reason: "owner_ended"},
               video_subject,
               fn _call -> :ok end
             )

    assert ended.media_kind == :video

    ended_event =
      Repo.get_by!(OutboxEvent,
        aggregate_id: first.id,
        event_type: "call.ended.v1"
      )

    assert ended_event.payload["media_kind"] == "video"

    refute Repo.get_by(OutboxEvent,
             aggregate_id: first.id,
             event_type: "audio_call.ended.v1"
           )

    started_event =
      Repo.get_by!(OutboxEvent,
        aggregate_id: first.id,
        event_type: "call.started.v1"
      )

    assert started_event.payload["media_kind"] == "video"

    refute Repo.get_by(OutboxEvent,
             aggregate_id: first.id,
             event_type: "audio_call.started.v1"
           )

    audio = Fixtures.account_fixture()
    audio_subject = Fixtures.subject(audio)
    assert {:ok, _call, :created} = AudioCalls.start(audio.conversation.id, audio_subject)

    assert {:error, :call_media_kind_conflict} =
             AudioCalls.start(audio.conversation.id, audio_subject, :video)
  end

  test "video calls use the same lifecycle for direct and group conversations" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    member = signed_in_member(account)

    assert {:ok, direct} =
             Conversations.create(
               %{kind: "direct", member_ids: [member.user.id]},
               subject
             )

    assert {:ok, group_call, :created} =
             AudioCalls.start(account.conversation.id, subject, :video)

    assert {:ok, direct_call, :created} = AudioCalls.start(direct.id, subject, :video)
    assert group_call.media_kind == :video
    assert direct_call.media_kind == :video

    assert {:ok, ^direct_call, :joined} =
             AudioCalls.with_join_authorized(
               direct.id,
               direct_call.id,
               Fixtures.subject(member),
               fn _call, _participant -> {:ok, :joined} end
             )
  end

  test "video authorization is independently tenant controlled" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    settings = Repo.get_by(TenantSettings, tenant_id: account.tenant.id)

    (settings || %TenantSettings{tenant_id: account.tenant.id})
    |> TenantSettings.changeset(%{allow_video_calls: false})
    |> Repo.insert_or_update!()

    assert {:error, :video_calls_disabled} =
             AudioCalls.start(account.conversation.id, subject, :video)

    assert {:ok, audio_call, :created} = AudioCalls.start(account.conversation.id, subject)
    assert audio_call.media_kind == :audio
  end

  test "tenant video disable revokes only video admissions and denies future joins" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    member = Fixtures.user_fixture(account)

    assert {:ok, direct} =
             Conversations.create(%{kind: "direct", member_ids: [member.user.id]}, subject)

    assert {:ok, video_call, :created} =
             AudioCalls.start(account.conversation.id, subject, :video)

    assert {:ok, audio_call, :created} = AudioCalls.start(direct.id, subject)

    issuer = fn _call, participant -> {:ok, participant.id} end

    assert {:ok, ^video_call, video_participant_id} =
             AudioCalls.with_join_authorized(
               account.conversation.id,
               video_call.id,
               subject,
               issuer
             )

    assert {:ok, ^audio_call, audio_participant_id} =
             AudioCalls.with_join_authorized(direct.id, audio_call.id, subject, issuer)

    assert {:ok, %{settings: %{allow_video_calls: false, allow_audio_calls: true}}} =
             Administration.update_tenant_settings(
               %{version: 1, allow_video_calls: false},
               subject
             )

    assert Repo.get!(AudioCallParticipant, video_participant_id).status == :revoked

    assert Repo.get!(AudioCallParticipant, video_participant_id).revocation_reason ==
             "tenant_video_disabled"

    assert Repo.get!(AudioCallParticipant, audio_participant_id).status == :admitted

    assert {:error, :video_calls_disabled} =
             AudioCalls.authorize_join(account.conversation.id, video_call.id, subject)

    assert {:ok, ^audio_call} = AudioCalls.authorize_join(direct.id, audio_call.id, subject)
  end

  test "legacy expected-kind joins cannot issue a video credential" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject, :video)

    assert {:error, :call_media_kind_conflict} =
             AudioCalls.with_join_authorized(
               account.conversation.id,
               call.id,
               subject,
               :audio,
               fn _call, _participant -> flunk("legacy audio issuer must not run") end
             )

    assert {:ok, ^call, :video_credential} =
             AudioCalls.with_join_authorized(
               account.conversation.id,
               call.id,
               subject,
               fn locked_call, _participant ->
                 assert locked_call.media_kind == :video
                 {:ok, :video_credential}
               end
             )
  end

  test "atomic start and starter credential issuance roll back every new-call artifact" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:error, :credential_issuer_failed} =
             AudioCalls.start_with_join_authorized(
               account.conversation.id,
               subject,
               :video,
               fn _call -> :ok end,
               fn _call, _participant -> {:error, :credential_issuer_failed} end
             )

    assert_no_call_start_artifacts(account.tenant.id)
  end

  test "tenant capability race cannot commit an orphaned call" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    parent = self()

    disable_task =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.one!(
            from(tenant in Tenant,
              where: tenant.id == ^account.tenant.id,
              lock: "FOR UPDATE"
            )
          )

          send(parent, :video_capability_lock_held)

          receive do
            :disable_video_and_commit -> :ok
          end

          settings =
            Repo.get_by(TenantSettings, tenant_id: account.tenant.id) ||
              %TenantSettings{tenant_id: account.tenant.id}

          settings
          |> TenantSettings.changeset(%{allow_video_calls: false})
          |> Repo.insert_or_update!()
        end)
      end)

    assert_receive :video_capability_lock_held

    start_task =
      Task.async(fn ->
        AudioCalls.start_with_join_authorized(
          account.conversation.id,
          subject,
          :video,
          fn _call -> :ok end,
          fn _call, _participant ->
            send(parent, :capability_race_issuer_ran)
            {:ok, :credential}
          end
        )
      end)

    refute_receive :capability_race_issuer_ran, 100
    send(disable_task.pid, :disable_video_and_commit)
    assert {:ok, %TenantSettings{allow_video_calls: false}} = Task.await(disable_task, 5_000)
    assert {:error, :video_calls_disabled} = Task.await(start_task, 5_000)
    refute_received :capability_race_issuer_ran
    assert_no_call_start_artifacts(account.tenant.id)
  end

  test "session revocation race cannot commit an orphaned call" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    parent = self()

    revoke_task =
      Task.async(fn ->
        Repo.transaction(fn ->
          session =
            Repo.one!(
              from(session in Session,
                where: session.id == ^account.session.id,
                lock: "FOR UPDATE"
              )
            )

          send(parent, :session_revocation_lock_held)

          receive do
            :revoke_session_and_commit -> :ok
          end

          session
          |> Session.changeset(%{revoked_at: now()})
          |> Repo.update!()
        end)
      end)

    assert_receive :session_revocation_lock_held

    start_task =
      Task.async(fn ->
        AudioCalls.start_with_join_authorized(
          account.conversation.id,
          subject,
          :video,
          fn _call -> :ok end,
          fn _call, _participant ->
            send(parent, :session_race_issuer_ran)
            {:ok, :credential}
          end
        )
      end)

    refute_receive :session_race_issuer_ran, 100
    send(revoke_task.pid, :revoke_session_and_commit)
    assert {:ok, %Session{revoked_at: %DateTime{}}} = Task.await(revoke_task, 5_000)
    assert {:error, :forbidden} = Task.await(start_task, 5_000)
    refute_received :session_race_issuer_ran
    assert_no_call_start_artifacts(account.tenant.id)
  end

  test "concurrent starts resolve to one active call" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    results =
      1..3
      |> Enum.map(fn _ ->
        Task.async(fn -> AudioCalls.start(account.conversation.id, subject) end)
      end)
      |> Enum.map(&Task.await(&1, 10_000))

    ids = Enum.map(results, fn {:ok, call, _status} -> call.id end)
    assert ids |> Enum.uniq() |> length() == 1
    assert Repo.aggregate(from(call in AudioCall, where: call.status == :active), :count) == 1
  end

  test "an expired call is not joinable and the next start replaces it" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)

    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    AudioCall
    |> where([record], record.id == ^call.id)
    |> Repo.update_all(
      set: [started_at: DateTime.add(timestamp, -3_600), expires_at: DateTime.add(timestamp, -1)]
    )

    assert {:error, :audio_call_expired} =
             AudioCalls.authorize_join(account.conversation.id, call.id, subject)

    test_pid = self()

    assert {:ok, replacement, :created} =
             AudioCalls.start(account.conversation.id, subject, fn expired_call ->
               send(test_pid, {:deleted_expired_provider_room, expired_call})
               :ok
             end)

    assert_receive {:deleted_expired_provider_room, deleted_call}
    assert deleted_call.id == call.id
    assert deleted_call.provider_room == call.provider_room
    assert deleted_call.status == :ending
    refute replacement.id == call.id
    assert Repo.get!(AudioCall, call.id).status == :ended
  end

  test "provider failure rolls back expired replacement and leaves the old call recoverable" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)

    timestamp = now()

    AudioCall
    |> where([record], record.id == ^call.id)
    |> Repo.update_all(
      set: [started_at: DateTime.add(timestamp, -3_600), expires_at: DateTime.add(timestamp, -1)]
    )

    assert {:error, :audio_provider_unavailable} =
             AudioCalls.start(account.conversation.id, subject, fn ending_call ->
               assert ending_call.status == :ending
               {:error, :audio_provider_unavailable}
             end)

    persisted = Repo.get!(AudioCall, call.id)
    assert persisted.status == :active
    assert is_nil(persisted.ended_at)
    assert Repo.aggregate(AudioCall, :count) == 1

    refute Audit.get_by(%{
             tenant_id: account.tenant.id,
             resource_id: call.id,
             action: "audio_call.end"
           })
  end

  test "tenant disablement, cross-tenant access, membership removal, and session revocation fail closed" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    settings = Repo.get_by(TenantSettings, tenant_id: account.tenant.id)

    (settings || %TenantSettings{tenant_id: account.tenant.id})
    |> TenantSettings.changeset(%{allow_audio_calls: false})
    |> Repo.insert_or_update!()

    assert {:error, :audio_calls_disabled} = AudioCalls.start(account.conversation.id, subject)

    Repo.get_by!(TenantSettings, tenant_id: account.tenant.id)
    |> TenantSettings.changeset(%{allow_audio_calls: true})
    |> Repo.update!()

    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)
    other = Fixtures.account_fixture()

    assert {:error, :forbidden} =
             AudioCalls.authorize_join(
               account.conversation.id,
               call.id,
               Fixtures.subject(other)
             )

    membership =
      Repo.get_by!(Membership,
        conversation_id: account.conversation.id,
        user_id: account.user.id
      )

    membership |> Membership.changeset(%{left_at: now()}) |> Repo.update!()

    assert {:error, :forbidden} =
             AudioCalls.authorize_join(account.conversation.id, call.id, subject)

    membership |> Membership.changeset(%{left_at: nil}) |> Repo.update!()
    assert :ok = Accounts.revoke_session(account.session.id, account.user.id)

    assert {:error, :forbidden} =
             AudioCalls.authorize_join(account.conversation.id, call.id, subject)
  end

  test "starter and conversation moderators may end while ordinary members may not" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    member = signed_in_member(account)

    assert {:ok, membership} =
             Conversations.add_member(
               account.conversation.id,
               member.user.id,
               :member,
               subject
             )

    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)

    assert {:error, :forbidden} =
             AudioCalls.end_call(
               account.conversation.id,
               call.id,
               %{},
               Fixtures.subject(member),
               fn _call -> :ok end
             )

    membership |> Membership.changeset(%{role: :moderator}) |> Repo.update!()

    assert {:ok, ended} =
             AudioCalls.end_call(
               account.conversation.id,
               call.id,
               %{reason: "moderator_ended"},
               Fixtures.subject(member),
               fn _call -> :ok end
             )

    assert ended.status == :ended
    assert ended.ended_by_user_id == member.user.id
    assert ended.end_reason == "moderator_ended"
  end

  test "end authorization validates and normalizes the reason before provider orchestration" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)

    assert {:error, :invalid_end_reason} =
             AudioCalls.authorize_end(
               account.conversation.id,
               call.id,
               %{reason: "  "},
               subject
             )

    assert {:ok, authorized_call, "owner_ended"} =
             AudioCalls.authorize_end(
               account.conversation.id,
               call.id,
               %{reason: "  owner_ended  "},
               subject
             )

    assert authorized_call.id == call.id
    assert Repo.get!(AudioCall, call.id).status == :active
  end

  test "provider failure rolls the ending transition back to active without end evidence" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)

    assert {:error, :audio_provider_unavailable} =
             AudioCalls.end_call(
               account.conversation.id,
               call.id,
               %{reason: "owner_ended"},
               subject,
               fn ending_call ->
                 assert ending_call.status == :ending
                 {:error, :audio_provider_unavailable}
               end
             )

    persisted = Repo.get!(AudioCall, call.id)
    assert persisted.status == :active
    assert is_nil(persisted.ended_at)
    assert is_nil(persisted.end_reason)

    refute Audit.get_by(%{
             tenant_id: account.tenant.id,
             resource_id: call.id,
             action: "audio_call.end"
           })

    refute Repo.get_by(OutboxEvent,
             aggregate_id: call.id,
             event_type: "audio_call.ended.v1"
           )
  end

  test "join token issuance cannot run after ending starts" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)
    test_pid = self()

    end_task =
      Task.async(fn ->
        AudioCalls.end_call(
          account.conversation.id,
          call.id,
          %{reason: "owner_ended"},
          subject,
          fn ending_call ->
            send(test_pid, {:provider_delete_started, ending_call.status})

            receive do
              :finish_provider_delete -> :ok
            end
          end
        )
      end)

    assert_receive {:provider_delete_started, :ending}

    join_task =
      Task.async(fn ->
        AudioCalls.with_join_authorized(
          account.conversation.id,
          call.id,
          subject,
          fn _locked_call, _participant ->
            send(test_pid, :join_token_issuer_ran)
            {:ok, :credential}
          end
        )
      end)

    refute_receive :join_token_issuer_ran, 100
    send(end_task.pid, :finish_provider_delete)

    assert {:ok, %AudioCall{status: :ended}} = Task.await(end_task, 5_000)
    assert {:error, :audio_call_ended} = Task.await(join_task, 5_000)
    refute_received :join_token_issuer_ran
  end

  test "an in-flight join credential completes before a later end transition" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)
    test_pid = self()

    join_task =
      Task.async(fn ->
        AudioCalls.with_join_authorized(
          account.conversation.id,
          call.id,
          subject,
          fn _locked_call, _participant ->
            send(test_pid, :join_issuer_started)

            receive do
              :finish_join_issuer -> {:ok, :credential}
            end
          end
        )
      end)

    assert_receive :join_issuer_started

    end_task =
      Task.async(fn ->
        AudioCalls.end_call(
          account.conversation.id,
          call.id,
          %{reason: "owner_ended"},
          subject,
          fn ending_call ->
            send(test_pid, {:later_provider_delete_started, ending_call.status})
            :ok
          end
        )
      end)

    refute_receive {:later_provider_delete_started, _status}, 100
    send(join_task.pid, :finish_join_issuer)

    assert {:ok, %AudioCall{id: call_id}, :credential} = Task.await(join_task, 5_000)
    assert call_id == call.id
    assert_receive {:later_provider_delete_started, :ending}
    assert {:ok, %AudioCall{status: :ended}} = Task.await(end_task, 5_000)
  end

  test "admission creation, reuse, and credential issuance are atomic without token persistence" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)

    issuer = fn locked_call, participant ->
      assert locked_call.id == call.id
      assert participant.provider_identity =~ "kc_"
      {:ok, %{participant_token: "must-never-be-persisted", server_url: "wss://audio.test"}}
    end

    assert {:ok, ^call, credential} =
             AudioCalls.with_join_authorized(account.conversation.id, call.id, subject, issuer)

    assert credential.participant_token == "must-never-be-persisted"
    participant = Repo.one!(AudioCallParticipant)
    assert participant.status == :admitted
    assert participant.credential_issue_count == 1
    assert participant.credential_issued_at
    refute inspect(participant) =~ "must-never-be-persisted"

    first_identity = participant.provider_identity

    assert {:ok, ^call, _credential} =
             AudioCalls.with_join_authorized(account.conversation.id, call.id, subject, issuer)

    reused = Repo.one!(AudioCallParticipant)
    assert reused.id == participant.id
    assert reused.provider_identity == first_identity
    assert reused.credential_issue_count == 2

    other = Fixtures.account_fixture()
    other_subject = Fixtures.subject(other)
    assert {:ok, other_call, :created} = AudioCalls.start(other.conversation.id, other_subject)

    assert {:error, :forced_issuer_failure} =
             AudioCalls.with_join_authorized(
               other.conversation.id,
               other_call.id,
               other_subject,
               fn _locked_call, _participant -> {:error, :forced_issuer_failure} end
             )

    refute Repo.get_by(AudioCallParticipant, audio_call_id: other_call.id)
  end

  test "every revocation scope creates an immutable replacement admission and durable eviction job" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)

    scopes = [
      fn ->
        AudioCalls.revoke_for_sessions(account.tenant.id, [account.session.id], "session_revoked")
      end,
      fn ->
        AudioCalls.revoke_for_device(account.tenant.id, account.device.id, "device_revoked")
      end,
      fn -> AudioCalls.revoke_for_user(account.tenant.id, account.user.id, "user_revoked") end,
      fn ->
        AudioCalls.revoke_for_membership(
          account.tenant.id,
          account.conversation.id,
          account.user.id,
          "membership_removed"
        )
      end,
      fn ->
        AudioCalls.revoke_for_conversation(
          account.tenant.id,
          account.conversation.id,
          "conversation_archived"
        )
      end,
      fn -> AudioCalls.revoke_for_tenant(account.tenant.id, "tenant_audio_disabled") end,
      fn -> AudioCalls.revoke_for_call(account.tenant.id, call.id, "call_ended") end
    ]

    identities =
      Enum.map(scopes, fn revoke ->
        assert {:ok, ^call, identity} =
                 AudioCalls.with_join_authorized(
                   account.conversation.id,
                   call.id,
                   subject,
                   fn _locked_call, participant -> {:ok, participant.provider_identity} end
                 )

        assert {:ok, 1} = revoke.()
        identity
      end)

    assert length(Enum.uniq(identities)) == length(scopes)

    participants =
      AudioCallParticipant
      |> where([participant], participant.audio_call_id == ^call.id)
      |> order_by([participant], asc: participant.admitted_at)
      |> Repo.all()

    assert length(participants) == length(scopes)

    assert Enum.all?(participants, fn participant ->
             (participant.status == :revoked and participant.eviction_status == :pending and
                participant.revoked_at) && participant.eviction_enforce_until &&
               is_nil(participant.last_eviction_attempt_at)
           end)

    participant_ids = Enum.map(participants, & &1.id)

    jobs =
      Repo.all(
        from(job in Oban.Job,
          where:
            job.worker == "CommsWorkers.AudioParticipantEvictionWorker" and
              fragment("?->>'participant_id'", job.args) in ^participant_ids
        )
      )

    assert length(jobs) == length(scopes)
  end

  test "a credential admitted before session revocation is durably queued for eviction" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)
    parent = self()

    join_task =
      Task.async(fn ->
        AudioCalls.with_join_authorized(
          account.conversation.id,
          call.id,
          subject,
          fn _locked_call, participant ->
            send(parent, {:issuer_locked_authority, participant.id})

            receive do
              :finish_credential -> {:ok, :credential}
            end
          end
        )
      end)

    assert_receive {:issuer_locked_authority, participant_id}

    revoke_task =
      Task.async(fn ->
        result = Accounts.revoke_session(account.session.id, account.user.id)
        send(parent, {:session_revoke_finished, result})
        result
      end)

    refute_receive {:session_revoke_finished, _result}, 100
    send(join_task.pid, :finish_credential)

    assert {:ok, %AudioCall{id: call_id}, :credential} = Task.await(join_task, 5_000)
    assert call_id == call.id
    assert :ok = Task.await(revoke_task, 5_000)
    assert_receive {:session_revoke_finished, :ok}

    participant = Repo.get!(AudioCallParticipant, participant_id)
    assert participant.status == :revoked
    assert participant.eviction_status == :pending

    assert Repo.exists?(
             from(job in Oban.Job,
               where:
                 job.worker == "CommsWorkers.AudioParticipantEvictionWorker" and
                   fragment("?->>'participant_id'", job.args) == ^participant.id
             )
           )
  end

  test "session revocation holding the authority lock prevents a later credential callback" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)
    parent = self()

    revoker =
      Task.async(fn ->
        Repo.transaction(fn ->
          session =
            Repo.one!(
              from(session in CommsCore.Accounts.Session,
                where: session.id == ^account.session.id,
                lock: "FOR UPDATE"
              )
            )

          session
          |> CommsCore.Accounts.Session.changeset(%{revoked_at: now()})
          |> Repo.update!()

          send(parent, :session_revocation_locked)

          receive do
            :commit_session_revocation -> :ok
          end
        end)
      end)

    assert_receive :session_revocation_locked

    join_task =
      Task.async(fn ->
        AudioCalls.with_join_authorized(
          account.conversation.id,
          call.id,
          subject,
          fn _locked_call, _participant ->
            send(parent, :credential_callback_ran)
            {:ok, :credential}
          end
        )
      end)

    refute_receive :credential_callback_ran, 100
    send(revoker.pid, :commit_session_revocation)
    assert {:ok, :ok} = Task.await(revoker, 5_000)
    assert {:error, :forbidden} = Task.await(join_task, 5_000)
    refute_received :credential_callback_ran
    refute Repo.get_by(AudioCallParticipant, audio_call_id: call.id)
  end

  test "tenant audio disable waits for an in-flight admission then queues its eviction" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)
    parent = self()

    join_task =
      Task.async(fn ->
        AudioCalls.with_join_authorized(
          account.conversation.id,
          call.id,
          subject,
          fn _locked_call, participant ->
            send(parent, {:tenant_race_issuer_started, participant.id})

            receive do
              :finish_tenant_race_issuer -> {:ok, :credential}
            end
          end
        )
      end)

    assert_receive {:tenant_race_issuer_started, participant_id}

    disable_task =
      Task.async(fn ->
        result =
          Administration.update_tenant_settings(
            %{version: 1, allow_audio_calls: false},
            subject
          )

        send(parent, {:tenant_audio_disable_finished, result})
        result
      end)

    refute_receive {:tenant_audio_disable_finished, _result}, 100
    send(join_task.pid, :finish_tenant_race_issuer)
    assert {:ok, %AudioCall{}, :credential} = Task.await(join_task, 5_000)
    assert {:ok, %{settings: %{allow_audio_calls: false}}} = Task.await(disable_task, 5_000)

    participant = Repo.get!(AudioCallParticipant, participant_id)
    assert participant.status == :revoked
    assert participant.revocation_reason == "tenant_audio_disabled"
  end

  test "conversation archive waits for an in-flight admission then queues its eviction" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)
    parent = self()

    join_task =
      Task.async(fn ->
        AudioCalls.with_join_authorized(
          account.conversation.id,
          call.id,
          subject,
          fn _locked_call, participant ->
            send(parent, {:archive_race_issuer_started, participant.id})

            receive do
              :finish_archive_race_issuer -> {:ok, :credential}
            end
          end
        )
      end)

    assert_receive {:archive_race_issuer_started, participant_id}

    archive_task =
      Task.async(fn ->
        result =
          Conversations.archive(
            account.conversation.id,
            %{version: account.conversation.lock_version},
            subject
          )

        send(parent, {:conversation_archive_finished, result})
        result
      end)

    refute_receive {:conversation_archive_finished, _result}, 100
    send(join_task.pid, :finish_archive_race_issuer)
    assert {:ok, %AudioCall{}, :credential} = Task.await(join_task, 5_000)
    assert {:ok, %{archived_at: %DateTime{}}} = Task.await(archive_task, 5_000)

    participant = Repo.get!(AudioCallParticipant, participant_id)
    assert participant.status == :revoked
    assert participant.revocation_reason == "conversation_archived"
  end

  test "later identity revocation does not enqueue historical-call eviction work again" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)

    assert {:ok, ^call, :credential} =
             AudioCalls.with_join_authorized(
               account.conversation.id,
               call.id,
               subject,
               fn _locked_call, _participant -> {:ok, :credential} end
             )

    assert {:ok, %AudioCall{status: :ended}} =
             AudioCalls.end_call(
               account.conversation.id,
               call.id,
               %{reason: "owner_ended"},
               subject,
               fn _ending_call -> :ok end
             )

    participant = Repo.get_by!(AudioCallParticipant, audio_call_id: call.id)
    assert participant.status == :revoked
    assert participant.revocation_reason == "call_ended"
    jobs_before = eviction_job_count(participant.id)
    assert jobs_before == 1

    assert :ok = Accounts.revoke_session(account.session.id, account.user.id)
    assert eviction_job_count(participant.id) == jobs_before
  end

  defp signed_in_member(account) do
    member = Fixtures.user_fixture(account)
    [local, _domain] = String.split(member.user.email, "@", parts: 2)
    suffix = String.replace_prefix(local, "member-", "")

    {:ok, signed_in} =
      Accounts.authenticate(
        account.tenant.slug,
        member.user.email,
        "correct-horse-battery-#{suffix}",
        %{name: "Member browser", platform: "test"}
      )

    signed_in
  end

  defp eviction_job_count(participant_id) do
    Repo.aggregate(
      from(job in Oban.Job,
        where:
          job.worker == "CommsWorkers.AudioParticipantEvictionWorker" and
            fragment("?->>'participant_id'", job.args) == ^participant_id
      ),
      :count
    )
  end

  defp assert_no_call_start_artifacts(tenant_id) do
    assert Repo.aggregate(AudioCall, :count) == 0
    assert Repo.aggregate(AudioCallParticipant, :count) == 0

    assert Repo.aggregate(
             from(event in OutboxEvent,
               where: event.event_type in ["call.started.v1", "audio_call.started.v1"]
             ),
             :count
           ) == 0

    assert Audit.count(%{tenant_id: tenant_id, action: "audio_call.start"}) == 0
    assert Audit.count(%{tenant_id: tenant_id, action: "video_call.start"}) == 0

    assert Repo.aggregate(
             from(job in Oban.Job,
               where: job.worker == "CommsWorkers.AudioCallExpiryWorker"
             ),
             :count
           ) == 0
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
