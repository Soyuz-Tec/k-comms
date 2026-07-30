defmodule CommsCore.AudioCalls.StartTest do
  use CommsCore.DataCase, async: false

  @moduletag :call
  @moduletag :integration

  alias CommsCore.AudioCalls
  alias CommsCore.AudioCalls.AudioCall
  alias CommsCore.Audit
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
end
