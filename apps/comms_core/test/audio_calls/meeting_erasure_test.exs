defmodule CommsCore.AudioCalls.MeetingErasureTest do
  use CommsCore.DataCase, async: false
  @moduletag :integration
  @moduletag :governance
  alias CommsCore.{Accounts, AudioCalls, Conversations, Governance, Release}
  alias CommsCore.AudioCalls.{Meeting, MeetingOccurrence, MeetingErasurePlan}
  alias CommsCore.Events.OutboxEvent
  alias CommsTestSupport.Fixtures

  test "active and cancelled host metadata is scrubbed and no remaining member can read, search or export it" do
    account = Fixtures.account_fixture()
    host = Fixtures.subject(account)
    member = member(account)
    {:ok, _} = Conversations.add_member(account.conversation.id, member.user.id, :member, host)

    {:ok, active} =
      AudioCalls.schedule_meeting(account.conversation.id, input("Private active title"), host)

    {:ok, cancelled} =
      AudioCalls.schedule_meeting(account.conversation.id, input("Private cancelled title"), host)

    {:ok, cancelled} = AudioCalls.cancel_meeting(cancelled.id, %{expected_version: 1}, host)
    assert {:ok, before} = AudioCalls.meeting_calendar(cancelled.id, member.subject)
    assert before =~ "Private cancelled title"
    assert AudioCalls.rollback_meeting_hazard_count() > 0

    assert {:ok, true} =
             AudioCalls.meeting_governance_erasure_pending?(
               account.tenant.id,
               :user,
               account.user.id
             )

    assert {:ok, {:ok, %MeetingErasurePlan{pending_meeting_count: 0, scrubbed_meeting_count: 2}}} =
             prepare(account, :user, account.user.id)

    for meeting <- [active, cancelled] do
      assert {:error, :not_found} = AudioCalls.get_meeting(meeting.id, member.subject)
      assert {:error, :not_found} = AudioCalls.meeting_calendar(meeting.id, member.subject)
      row = Repo.get!(Meeting, meeting.id)
      assert row.title == "[Deleted meeting]"
      assert row.host_user_id == nil
      assert row.author_user_ids == []
      assert row.erased_at && row.erasure_requested_at
      refute inspect(row) =~ "Private"
    end

    assert {:ok, %{meetings: []}} = AudioCalls.list_meetings(member.subject, %{})
    assert {:ok, %{meetings: []}} = AudioCalls.search_meetings(member.subject, %{q: "Private"})

    assert {:ok, false} =
             AudioCalls.meeting_governance_erasure_pending?(
               account.tenant.id,
               :user,
               account.user.id
             )

    assert AudioCalls.rollback_meeting_hazard_count() == 0
  end

  test "conversation erasure scrubs all hosts and preserves an unrelated conversation" do
    account = Fixtures.account_fixture()
    host = Fixtures.subject(account)
    member = member(account)
    {:ok, _} = Conversations.add_member(account.conversation.id, member.user.id, :member, host)
    {:ok, first} = AudioCalls.schedule_meeting(account.conversation.id, input("Host first"), host)

    {:ok, second} =
      AudioCalls.schedule_meeting(account.conversation.id, input("Host second"), member.subject)

    {:ok, other} = Conversations.create(%{kind: :group, title: "Unaffected"}, host)
    {:ok, retained} = AudioCalls.schedule_meeting(other.id, input("Retained content"), host)

    assert {:ok, {:ok, %{scrubbed_meeting_count: 2}}} =
             prepare(account, :conversation, account.conversation.id)

    for id <- [first.id, second.id], do: assert(Repo.get!(Meeting, id).erased_at)
    assert {:ok, %{title: "Retained content"}} = AudioCalls.get_meeting(retained.id, host)

    assert {:ok, false} =
             AudioCalls.meeting_governance_erasure_pending?(
               account.tenant.id,
               :conversation,
               account.conversation.id
             )
  end

  test "a held cancelled title remains protected, then disappears from ICS after authorized release and erasure" do
    account = Fixtures.account_fixture()
    host = Fixtures.step_up(account)

    {:ok, meeting} =
      AudioCalls.schedule_meeting(account.conversation.id, input("Held private title"), host)

    {:ok, _} = AudioCalls.cancel_meeting(meeting.id, %{expected_version: 1}, host)

    {:ok, result} =
      Governance.create_legal_hold(
        %{
          scope_type: :user,
          subject_user_id: account.user.id,
          name: "Meeting preservation",
          reason: "Preserve authored meeting content"
        },
        host
      )

    assert {:error, :legal_hold_active} =
             Repo.transaction(fn ->
               Repo.get!(Meeting, meeting.id)
               |> Ecto.Changeset.change(title: "Transient preparation content")
               |> Repo.update!()

               assert {:error, :meeting_legal_hold} =
                        AudioCalls.prepare_meeting_governance_erasure(
                          account.tenant.id,
                          :user,
                          account.user.id
                        )

               # Governance maps the returned owner error and rolls back the whole claim.
               Repo.rollback(:legal_hold_active)
             end)

    assert Repo.get!(Meeting, meeting.id).title == "Held private title"
    assert Repo.get!(Meeting, meeting.id).erased_at == nil
    assert {:ok, calendar} = AudioCalls.meeting_calendar(meeting.id, host)
    assert calendar =~ "Held private title"
    assert AudioCalls.rollback_meeting_hazard_count() > 0

    {:ok, _} =
      Governance.release_legal_hold(
        result.hold.id,
        %{version: result.hold.lock_version, release_reason: "Authorized evidence release"},
        host
      )

    assert {:ok, {:ok, _}} = prepare(account, :user, account.user.id)
    assert {:error, :not_found} = AudioCalls.meeting_calendar(meeting.id, host)
  end

  test "moderator title authorship and its legal hold are honored even for a different original host" do
    account = Fixtures.account_fixture()
    host = Fixtures.step_up(account)
    moderator = member(account)

    {:ok, _} =
      Conversations.add_member(account.conversation.id, moderator.user.id, :moderator, host)

    {:ok, meeting} =
      AudioCalls.schedule_meeting(account.conversation.id, input("Host title"), host)

    {:ok, _} =
      AudioCalls.update_meeting(
        meeting.id,
        Map.put(input("Moderator private title"), :expected_version, 1),
        moderator.subject
      )

    assert moderator.user.id in Repo.get!(Meeting, meeting.id).author_user_ids

    {:ok, result} =
      Governance.create_legal_hold(
        %{
          scope_type: :user,
          subject_user_id: moderator.user.id,
          name: "Moderator preservation",
          reason: "Preserve moderated private title"
        },
        host
      )

    assert {:error, :meeting_legal_hold} =
             prepare(account, :conversation, account.conversation.id)

    assert Repo.get!(Meeting, meeting.id).title == "Moderator private title"

    {:ok, _} =
      Governance.release_legal_hold(
        result.hold.id,
        %{version: result.hold.lock_version, release_reason: "Authorized evidence release"},
        host
      )

    # Simulate a row from before migration 11: owner repair consumes typed audit projections.
    Repo.get!(Meeting, meeting.id)
    |> Ecto.Changeset.change(author_user_ids: [], author_lineage_complete: false)
    |> Repo.update!()

    assert {:ok, {:ok, %{scrubbed_meeting_count: 1}}} = prepare(account, :user, moderator.user.id)
    assert {:error, :not_found} = AudioCalls.meeting_calendar(meeting.id, host)
  end

  test "approved erasure fences concurrent create, start, export and late reminders before preparation" do
    account = Fixtures.account_fixture()
    host = Fixtures.step_up(account)

    {:ok, meeting} =
      AudioCalls.schedule_meeting(account.conversation.id, input("Fenced title"), host)

    {:ok, request} =
      Governance.create_deletion_request(
        %{
          target_type: :conversation,
          conversation_id: account.conversation.id,
          reason: "Requested conversation erasure"
        },
        host
      )

    {:ok, _} =
      Governance.transition_deletion_request(
        request.request.id,
        %{
          version: request.request.lock_version,
          status: "approved",
          transition_reason: "Verified synthetic request"
        },
        host
      )

    commands = [
      fn ->
        AudioCalls.schedule_meeting(account.conversation.id, input("Late recreation"), host)
      end,
      fn ->
        AudioCalls.start_meeting(
          meeting.id,
          hd(meeting.occurrences).id,
          host,
          :audio,
          fn _ -> :ok end,
          fn _ -> flunk("erasing scope issued credential") end
        )
      end
    ]

    results =
      commands
      |> Task.async_stream(fn command -> command.() end, max_concurrency: 2)
      |> Enum.map(fn {:ok, result} -> result end)

    assert results == [{:error, :meeting_erasure_pending}, {:error, :meeting_erasure_pending}]
    assert {:error, :not_found} = AudioCalls.meeting_calendar(meeting.id, host)

    assert {:ok, :ignored} =
             AudioCalls.deliver_meeting_reminder(
               hd(meeting.occurrences).id,
               1,
               CommsWorkers.MeetingReminderWorker
             )

    refute Repo.get_by(OutboxEvent, aggregate_id: meeting.id, event_type: "meeting.reminder.v1")
  end

  test "late jobs and starts cannot recreate scrubbed metadata and cancelled reminders stay cancelled" do
    account = Fixtures.account_fixture()
    host = Fixtures.subject(account)

    {:ok, meeting} =
      AudioCalls.schedule_meeting(account.conversation.id, input("Gone metadata"), host)

    assert {:ok, {:ok, _}} = prepare(account, :user, account.user.id)

    assert {:ok, :ignored} =
             AudioCalls.deliver_meeting_reminder(
               hd(meeting.occurrences).id,
               1,
               CommsWorkers.MeetingReminderWorker
             )

    assert {:error, :not_found} =
             AudioCalls.start_meeting(
               meeting.id,
               hd(meeting.occurrences).id,
               host,
               :video,
               fn _ -> :ok end,
               fn _ -> flunk("scrubbed schedule issued credential") end
             )

    job =
      Repo.get_by!(Oban.Job,
        worker: "CommsWorkers.MeetingReminderWorker",
        args: %{
          "tenant_id" => account.tenant.id,
          "occurrence_id" => hd(meeting.occurrences).id,
          "version" => 1
        }
      )

    assert job.state == "cancelled"

    assert DateTime.compare(
             Repo.get!(MeetingOccurrence, hd(meeting.occurrences).id).starts_at,
             ~U[1970-01-01 00:00:00Z]
           ) == :eq

    assert {:ok, {:ok, %{scrubbed_meeting_count: 0}}} = prepare(account, :user, account.user.id)
  end

  test "verification catches an unsanitized cancelled tombstone and an old target refuses it" do
    account = Fixtures.account_fixture()
    host = Fixtures.subject(account)

    {:ok, meeting} =
      AudioCalls.schedule_meeting(account.conversation.id, input("Private rollback title"), host)

    {:ok, _} = AudioCalls.cancel_meeting(meeting.id, %{expected_version: 1}, host)
    old_target = %{target_revision: "pre-meetings", capabilities: MapSet.new()}

    assert_raise RuntimeError, ~r/scheduled_meeting_lifecycle_v1/, fn ->
      Release.assert_communication_rollback_hazards!(
        rollback_hazards(AudioCalls.rollback_meeting_hazard_count()),
        old_target
      )
    end

    assert {:ok, {:ok, _}} = prepare(account, :user, account.user.id)

    Repo.get!(Meeting, meeting.id)
    |> Ecto.Changeset.change(title: "Unsanitized tampered title")
    |> Repo.update!()

    assert {:ok, true} =
             AudioCalls.meeting_governance_erasure_pending?(
               account.tenant.id,
               :user,
               account.user.id
             )

    assert AudioCalls.rollback_meeting_hazard_count() == 1
  end

  test "message erasure does not widen the schedule scope and invalid target identifiers are rejected" do
    account = Fixtures.account_fixture()

    {:ok, meeting} =
      AudioCalls.schedule_meeting(
        account.conversation.id,
        input("Unrelated title"),
        Fixtures.subject(account)
      )

    # DataCase already has a sandbox transaction, so exercise the no-op target and UUID validation here.
    assert {:ok, {:ok, %{scrubbed_meeting_count: 0}}} =
             prepare(account, :message, Ecto.UUID.generate())

    assert Repo.get!(Meeting, meeting.id).erased_at == nil

    assert {:error, :invalid_governance_target} =
             AudioCalls.meeting_governance_erasure_pending?(account.tenant.id, :user, "invalid")
  end

  test "unavailable historical authorship prevents reads and owner completion without scrubbing held evidence" do
    account = Fixtures.account_fixture()
    host = Fixtures.subject(account)

    {:ok, meeting} =
      AudioCalls.schedule_meeting(account.conversation.id, input("Unknown legacy author"), host)

    Repo.get!(Meeting, meeting.id)
    |> Ecto.Changeset.change(author_user_ids: [], author_lineage_complete: false, version: 2)
    |> Repo.update!()

    assert {:error, :meeting_authorship_unavailable} = AudioCalls.get_meeting(meeting.id, host)

    assert {:error, :meeting_authorship_unavailable} =
             AudioCalls.meeting_calendar(meeting.id, host)

    assert {:error, :meeting_authorship_unavailable} = prepare(account, :user, account.user.id)

    assert {:ok, true} =
             AudioCalls.meeting_governance_erasure_pending?(
               account.tenant.id,
               :user,
               account.user.id
             )

    assert Repo.get!(Meeting, meeting.id).title == "Unknown legacy author"
    assert AudioCalls.rollback_meeting_hazard_count() > 0
  end

  defp prepare(account, type, id) do
    Repo.transaction(fn ->
      case AudioCalls.prepare_meeting_governance_erasure(account.tenant.id, type, id) do
        {:ok, _} = result -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp rollback_hazards(count) do
    keys = [
      :guest_users,
      :active_guest_expiry_jobs,
      :ephemeral_rooms,
      :ephemeral_join_receipts,
      :ephemeral_presence_leases,
      :active_ephemeral_room_lifecycle_jobs,
      :active_ephemeral_room_reconciler_jobs,
      :conversation_only_humans,
      :enterprise_identities,
      :scim_credentials,
      :retained_call_artifacts,
      :active_artifact_jobs,
      :voicemail_media,
      :active_voicemail_jobs,
      :advanced_controls,
      :active_control_jobs,
      :active_routing_jobs,
      :scheduled_meetings,
      :active_meeting_reminder_jobs,
      :rich_messages,
      :rich_whiteboards,
      :member_workspaces,
      :governance_history_snapshots,
      :active_history_purge_jobs,
      :ivr_state,
      :agent_queue_states,
      :active_ivr_jobs
    ]

    keys |> Map.new(&{&1, 0}) |> Map.put(:scheduled_meetings, count)
  end

  defp input(title),
    do: %{
      title: title,
      timezone: "Etc/UTC",
      local_start:
        DateTime.utc_now()
        |> DateTime.add(120)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)
        |> NaiveDateTime.to_iso8601(),
      duration_minutes: 60,
      reminder_minutes: 10,
      recurrence: %{frequency: "none", interval: 1, count: 1},
      host_policy: %{allow_guests: false, join_before_host: false}
    }

  defp member(account) do
    fixture = Fixtures.user_fixture(account)
    [local, _] = String.split(fixture.user.email, "@", parts: 2)
    suffix = String.replace_prefix(local, "member-", "")

    {:ok, auth} =
      Accounts.authenticate_view(
        account.tenant.slug,
        fixture.user.email,
        "correct-horse-battery-#{suffix}",
        %{name: "Meeting erasure browser", platform: "test"}
      )

    {:ok, context} = Accounts.access_context(auth.session_id)
    %{user: auth.user, subject: context.subject}
  end
end
