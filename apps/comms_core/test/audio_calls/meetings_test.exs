defmodule CommsCore.AudioCalls.MeetingsTest do
  use CommsCore.DataCase, async: false
  @moduletag :integration
  @moduletag :call
  alias CommsCore.AudioCalls
  alias CommsCore.{Accounts, Conversations}
  alias CommsCore.AudioCalls.{AudioCallParticipant, Meeting, MeetingOccurrence, MeetingView}
  alias CommsCore.Events.OutboxEvent
  alias CommsTestSupport.Fixtures

  test "rollback refuses proof when owned occurrence inventory is absent" do
    # DataCase rolls back this DDL with the isolated synthetic test transaction.
    Repo.query!("DROP TABLE public.meeting_occurrences")

    assert_raise RuntimeError, "Calls meeting rollback inventory unavailable", fn ->
      AudioCalls.rollback_meeting_hazard_count()
    end
  end

  test "rollback hazards require verified metadata scrubbing and ended policy-linked calls" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert AudioCalls.rollback_meeting_hazard_count() == 0
    {:ok, meeting} = AudioCalls.schedule_meeting(account.conversation.id, input(120), subject)
    assert AudioCalls.rollback_meeting_hazard_count() == 2

    {:ok, result} =
      AudioCalls.start_meeting(
        meeting.id,
        hd(meeting.occurrences).id,
        subject,
        :video,
        fn _ -> :ok end,
        fn _ -> {:ok, %{server_url: "wss://test.invalid", participant_token: "synthetic"}} end
      )

    assert AudioCalls.rollback_meeting_hazard_count() == 3
    {:ok, _} = AudioCalls.cancel_meeting(meeting.id, %{expected_version: 1}, subject)
    assert AudioCalls.rollback_meeting_hazard_count() == 2

    {:ok, _} =
      AudioCalls.end_call(
        account.conversation.id,
        result.call.id,
        %{reason: "rollback_hazard_test"},
        subject,
        fn _ -> :ok end
      )

    assert AudioCalls.rollback_meeting_hazard_count() == 1

    assert {:ok, {:ok, _}} =
             Repo.transaction(fn ->
               AudioCalls.prepare_meeting_governance_erasure(
                 account.tenant.id,
                 :user,
                 account.user.id
               )
             end)

    assert AudioCalls.rollback_meeting_hazard_count() == 0
  end

  test "scheduling writes bounded durable occurrences, typed views and reminder jobs atomically" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, %MeetingView{} = meeting} =
             AudioCalls.schedule_meeting(account.conversation.id, input(3600, 3), subject)

    assert length(meeting.occurrences) == 3
    assert meeting.can_manage
    assert meeting.version == 1
    refute Map.has_key?(meeting, :__meta__)
    assert Repo.aggregate(Meeting, :count) == 1
    assert Repo.aggregate(MeetingOccurrence, :count) == 3

    assert Repo.aggregate(
             from(job in Oban.Job, where: job.worker == "CommsWorkers.MeetingReminderWorker"),
             :count
           ) == 3

    assert Repo.get_by!(OutboxEvent, aggregate_id: meeting.id, event_type: "meeting.scheduled.v1")
    assert {:ok, %{meetings: [listed], truncated: false}} = AudioCalls.list_meetings(subject, %{})
    assert listed.id == meeting.id
  end

  test "cross-tenant IDs and forged sessions cannot read, edit, cancel or schedule meetings" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, meeting} = AudioCalls.schedule_meeting(account.conversation.id, input(), subject)
    other = Fixtures.account_fixture() |> Fixtures.subject()
    assert {:error, :not_found} = AudioCalls.get_meeting(meeting.id, other)

    assert {:error, :not_found} =
             AudioCalls.update_meeting(meeting.id, Map.put(input(), :expected_version, 1), other)

    assert {:error, :not_found} =
             AudioCalls.cancel_meeting(meeting.id, %{expected_version: 1}, other)

    assert {:ok, %{meetings: []}} = AudioCalls.list_meetings(other, %{})
    forged = Map.put(subject, :session_id, Ecto.UUID.generate())

    assert {:error, :forbidden} =
             AudioCalls.schedule_meeting(account.conversation.id, input(), forged)

    assert {:error, :forbidden} = AudioCalls.get_meeting(meeting.id, forged)
  end

  test "versioned edits retire the old occurrences and stale reminder retries are harmless" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, first} = AudioCalls.schedule_meeting(account.conversation.id, input(), subject)
    old_occurrence = hd(first.occurrences)
    assert {:error, :version_required} = AudioCalls.update_meeting(first.id, input(), subject)

    assert {:error, :stale_version} =
             AudioCalls.update_meeting(first.id, Map.put(input(), :expected_version, 2), subject)

    assert {:ok, edited} =
             AudioCalls.update_meeting(first.id, Map.put(input(), :expected_version, 1), subject)

    assert edited.version == 2
    assert hd(edited.occurrences).id != old_occurrence.id
    assert Repo.get!(MeetingOccurrence, old_occurrence.id).status == :cancelled

    assert {:ok, :ignored} =
             AudioCalls.deliver_meeting_reminder(
               old_occurrence.id,
               1,
               CommsWorkers.MeetingReminderWorker
             )

    assert {:ok, cancelled} = AudioCalls.cancel_meeting(first.id, %{expected_version: 2}, subject)
    assert cancelled.version == 3
    assert cancelled.status == :cancelled

    assert {:ok, :ignored} =
             AudioCalls.deliver_meeting_reminder(
               hd(edited.occurrences).id,
               2,
               CommsWorkers.MeetingReminderWorker
             )

    refute Repo.get_by(OutboxEvent, aggregate_id: first.id, event_type: "meeting.reminder.v1")
  end

  test "reminder retries emit one durable event and reject an unbound worker" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, meeting} =
             AudioCalls.schedule_meeting(account.conversation.id, input(120), subject)

    occurrence = hd(meeting.occurrences)

    assert {:error, :forbidden} =
             AudioCalls.deliver_meeting_reminder(occurrence.id, 1, __MODULE__)

    assert {:ok, :delivered} =
             AudioCalls.deliver_meeting_reminder(
               occurrence.id,
               1,
               CommsWorkers.MeetingReminderWorker
             )

    assert {:ok, :already_delivered} =
             AudioCalls.deliver_meeting_reminder(
               occurrence.id,
               1,
               CommsWorkers.MeetingReminderWorker
             )

    assert Repo.aggregate(
             from(event in OutboxEvent,
               where:
                 event.aggregate_id == ^meeting.id and event.event_type == "meeting.reminder.v1"
             ),
             :count
           ) == 1
  end

  test "cancellation revokes active admissions and generic join cannot bypass meeting policy" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, meeting} =
             AudioCalls.schedule_meeting(account.conversation.id, input(120), subject)

    assert {:ok, result} =
             AudioCalls.start_meeting(
               meeting.id,
               hd(meeting.occurrences).id,
               subject,
               :video,
               fn _ -> :ok end,
               fn _ ->
                 {:ok, %{server_url: "wss://test.invalid", participant_token: "synthetic"}}
               end
             )

    assert {:ok, _cancelled} =
             AudioCalls.cancel_meeting(meeting.id, %{expected_version: 1}, subject)

    assert Repo.get_by!(AudioCallParticipant, audio_call_id: result.call.id).status == :revoked

    assert {:error, :meeting_cancelled} =
             AudioCalls.with_join_authorized(
               account.conversation.id,
               result.call.id,
               subject,
               :video,
               fn _ -> flunk("cancelled meeting issued a credential") end
             )

    assert Repo.exists?(
             from(job in Oban.Job,
               where: job.worker == "CommsWorkers.AudioParticipantEvictionWorker"
             )
           )
  end

  test "ordinary members cannot manage another host's schedule and removed members lose calendar access" do
    account = Fixtures.account_fixture()
    owner = Fixtures.subject(account)
    member = signed_in_member(account)

    assert {:ok, membership} =
             Conversations.add_member(account.conversation.id, member.user.id, :member, owner)

    assert {:ok, meeting} =
             AudioCalls.schedule_meeting(account.conversation.id, input(120), owner)

    assert {:ok, %{can_manage: false}} = AudioCalls.get_meeting(meeting.id, member.subject)

    assert {:error, :forbidden} =
             AudioCalls.update_meeting(
               meeting.id,
               Map.put(input(), :expected_version, 1),
               member.subject
             )

    assert {:error, :forbidden} =
             AudioCalls.cancel_meeting(meeting.id, %{expected_version: 1}, member.subject)

    assert {:error, :meeting_host_required} =
             AudioCalls.start_meeting(
               meeting.id,
               hd(meeting.occurrences).id,
               member.subject,
               :audio,
               fn _ -> :ok end,
               fn _ -> flunk("nonhost received initial credential") end
             )

    assert {:ok, _} =
             Conversations.remove_member(
               account.conversation.id,
               member.user.id,
               %{version: membership.lock_version},
               owner
             )

    assert {:error, :forbidden} = AudioCalls.get_meeting(meeting.id, member.subject)
    assert {:error, :forbidden} = AudioCalls.meeting_calendar(meeting.id, member.subject)
    assert {:ok, %{meetings: []}} = AudioCalls.list_meetings(member.subject, %{})
  end

  test "authorized guest links cannot bypass a members-only scheduled call or manage its calendar" do
    account = Fixtures.account_fixture()
    owner = Fixtures.subject(account)

    assert {:ok, %{token: token}} =
             Conversations.create_guest_link_view(
               account.conversation.id,
               %{expires_in_seconds: 3600},
               owner
             )

    assert {:ok, redemption} =
             Conversations.redeem_guest_link(
               token,
               %{
                 display_name: "Scheduled guest",
                 device: %{name: "Guest browser", platform: "test"},
                 request_id: "meeting-guest"
               }
             )

    assert {:ok, context} =
             Accounts.guest_access_context(redemption.authentication.session_id, "meeting-guest")

    guest =
      Map.merge(context.subject, %{
        guest_admission_id: redemption.admission.id,
        guest_conversation_id: redemption.conversation.id,
        guest_history_from_sequence: redemption.admission.history_from_sequence
      })

    assert {:ok, meeting} =
             AudioCalls.schedule_meeting(account.conversation.id, input(120), owner)

    assert {:error, :forbidden} = AudioCalls.get_meeting(meeting.id, guest)

    assert {:error, :forbidden} =
             AudioCalls.schedule_meeting(account.conversation.id, input(), guest)

    assert {:ok, started} =
             AudioCalls.start_meeting(
               meeting.id,
               hd(meeting.occurrences).id,
               owner,
               :audio,
               fn _ -> :ok end,
               fn _ -> {:ok, %{participant_token: "synthetic"}} end
             )

    assert {:error, :meeting_guests_disabled} =
             AudioCalls.with_join_authorized(
               account.conversation.id,
               started.call.id,
               guest,
               :audio,
               fn _ -> flunk("members-only meeting issued guest credential") end
             )
  end

  test "an unrelated active conversation call cannot be adopted as the scheduled meeting" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, meeting} =
             AudioCalls.schedule_meeting(account.conversation.id, input(120), subject)

    assert {:ok, _ordinary, :created} = AudioCalls.start(account.conversation.id, subject, :audio)

    assert {:error, :active_call_conflict} =
             AudioCalls.start_meeting(
               meeting.id,
               hd(meeting.occurrences).id,
               subject,
               :audio,
               fn _ -> :ok end,
               fn _ -> flunk("conflicting ordinary call issued scheduled credential") end
             )

    assert Repo.get!(MeetingOccurrence, hd(meeting.occurrences).id).call_id == nil
  end

  test "shortening recurrence exports cancelled tombstones for previously imported dates" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, meeting} =
             AudioCalls.schedule_meeting(account.conversation.id, input(3600, 3), subject)

    assert {:ok, _edited} =
             AudioCalls.update_meeting(
               meeting.id,
               Map.put(input(3600, 1), :expected_version, 1),
               subject
             )

    assert {:ok, calendar} = AudioCalls.meeting_calendar(meeting.id, subject)
    assert length(String.split(calendar, "BEGIN:VEVENT")) - 1 == 3
    assert length(String.split(calendar, "STATUS:CANCELLED")) - 1 == 2
    assert calendar =~ "UID:#{meeting.id}-3@k-comms"
    assert calendar =~ "SEQUENCE:2"
  end

  test "unified retrieval uses literal title matching, authorized scope and disclosed result bounds" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, exact} =
             AudioCalls.schedule_meeting(
               account.conversation.id,
               Map.put(input(), :title, "Planning 100%_ready"),
               subject
             )

    assert {:ok, _other} =
             AudioCalls.schedule_meeting(
               account.conversation.id,
               Map.put(input(), :title, "Planning ordinary"),
               subject
             )

    assert {:ok, %{meetings: [match], truncated: false}} =
             AudioCalls.search_meetings(subject, %{q: "%_", limit: 1})

    assert match.id == exact.id

    assert {:ok, %{meetings: [_], truncated: true}} =
             AudioCalls.search_meetings(subject, %{q: "planning", limit: 1})

    assert {:ok, %{meetings: [], truncated: false}} =
             AudioCalls.search_meetings(
               subject,
               %{q: "Planning", conversation_id: Ecto.UUID.generate()}
             )

    other = Fixtures.account_fixture() |> Fixtures.subject()

    assert {:ok, %{meetings: [], truncated: false}} =
             AudioCalls.search_meetings(other, %{q: "Planning"})
  end

  defp signed_in_member(account) do
    member = Fixtures.user_fixture(account)
    [local, _] = String.split(member.user.email, "@", parts: 2)
    suffix = String.replace_prefix(local, "member-", "")

    assert {:ok, signed_in} =
             Accounts.authenticate_view(
               account.tenant.slug,
               member.user.email,
               "correct-horse-battery-#{suffix}",
               %{name: "Member browser", platform: "test"}
             )

    assert {:ok, context} = Accounts.access_context(signed_in.session_id)
    %{user: signed_in.user, subject: context.subject}
  end

  defp input(seconds \\ 3600, count \\ 1) do
    local =
      DateTime.utc_now()
      |> DateTime.add(seconds)
      |> DateTime.to_naive()
      |> NaiveDateTime.truncate(:second)

    %{
      title: "Planning",
      timezone: "Etc/UTC",
      local_start: NaiveDateTime.to_iso8601(local),
      duration_minutes: 60,
      reminder_minutes: 10,
      recurrence: %{
        frequency: if(count == 1, do: "none", else: "weekly"),
        count: count,
        interval: 1
      },
      host_policy: %{allow_guests: false, join_before_host: false}
    }
  end
end
