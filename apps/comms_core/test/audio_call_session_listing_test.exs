defmodule CommsCore.AudioCallSessionListingTest do
  use CommsCore.DataCase, async: false

  @moduletag :integration
  @moduletag :call

  alias CommsCore.AudioCalls
  alias CommsCore.AudioCalls.{AudioCall, CallSessionView}
  alias CommsTestSupport.Fixtures

  test "lists truthful active and recent room sessions with stable cursors" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    ended_audio = start_and_end(account.conversation.id, subject, :audio)
    ended_video = start_and_end(account.conversation.id, subject, :video)

    shared_started_at =
      ended_video.started_at
      |> DateTime.add(-60, :second)
      |> DateTime.truncate(:microsecond)

    from(call in AudioCall, where: call.id in ^[ended_audio.id, ended_video.id])
    |> Repo.update_all(
      set: [
        started_at: shared_started_at,
        expires_at: DateTime.add(shared_started_at, 8 * 60 * 60, :second)
      ]
    )

    assert {:ok, first_page} =
             AudioCalls.list_sessions(subject, %{scope: :recent, limit: 1})

    assert [%CallSessionView{} = first] = first_page.calls
    assert first.status == :ended
    assert first.duration_seconds == DateTime.diff(first.ended_at, first.started_at, :second)
    refute first.can_end
    assert first_page.has_more
    assert is_binary(first_page.next_cursor)

    for unsupported <- [:ringing, :answered, :missed, :declined, :scheduled, :user_duration] do
      refute Map.has_key?(first, unsupported)
    end

    assert {:ok, second_page} =
             AudioCalls.list_sessions(subject, %{
               scope: "recent",
               limit: "1",
               cursor: first_page.next_cursor
             })

    assert [%CallSessionView{} = second] = second_page.calls
    assert second_page.next_cursor == nil
    refute second_page.has_more

    assert MapSet.new([first.id, second.id]) ==
             MapSet.new([ended_audio.id, ended_video.id])

    assert {:ok, %{calls: [video_only]}} =
             AudioCalls.list_sessions(subject, %{scope: :recent, media_kind: "video"})

    assert video_only.id == ended_video.id
    assert video_only.media_kind == :video

    assert {:ok, active, :created} =
             AudioCalls.start(account.conversation.id, subject, :audio)

    assert {:ok, %{calls: [%CallSessionView{} = active_session]}} =
             AudioCalls.list_sessions(subject, %{scope: "active"})

    assert active_session.id == active.id
    assert active_session.status == :active
    assert active_session.can_end
    assert active_session.duration_seconds >= 0
  end

  test "fails closed across tenants and for invalid list inputs" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, _call, :created} = AudioCalls.start(account.conversation.id, subject)

    other_account = Fixtures.account_fixture()
    other_subject = Fixtures.subject(other_account)
    assert {:ok, %{calls: []}} = AudioCalls.list_sessions(other_subject, %{scope: :active})

    assert {:error, :invalid_call_scope} =
             AudioCalls.list_sessions(subject, %{scope: "missed"})

    assert {:error, :invalid_media_kind} =
             AudioCalls.list_sessions(subject, %{media_kind: "screen"})

    assert {:error, :invalid_cursor} =
             AudioCalls.list_sessions(subject, %{cursor: "not-opaque"})

    assert {:error, :forbidden} =
             AudioCalls.list_sessions(Map.put(subject, :session_id, Ecto.UUID.generate()))
  end

  defp start_and_end(conversation_id, subject, media_kind) do
    assert {:ok, call, :created} =
             AudioCalls.start(conversation_id, subject, media_kind)

    assert {:ok, ended} =
             AudioCalls.end_call(
               conversation_id,
               call.id,
               %{reason: "listing_test"},
               subject,
               fn _provider_call -> :ok end
             )

    ended
  end
end
