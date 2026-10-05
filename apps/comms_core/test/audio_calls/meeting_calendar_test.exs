defmodule CommsCore.AudioCalls.MeetingCalendarTest do
  use ExUnit.Case, async: true
  alias CommsCore.AudioCalls.{MeetingCalendar, MeetingView}

  test "calendar is portable UTC, versioned, cancellation-aware and escapes injected text" do
    meeting = %MeetingView{
      id: "meeting-id",
      version: 3,
      title: "Planning, roadmap; next\r\nATTENDEE:evil",
      timezone: "America/New_York",
      status: :cancelled,
      occurrences: [
        %{sequence: 1, starts_at: ~U[2027-03-14 13:00:00Z], ends_at: ~U[2027-03-14 14:00:00Z]}
      ]
    }

    calendar = MeetingCalendar.render(meeting)
    assert calendar =~ "METHOD:CANCEL\r\n"
    assert calendar =~ "STATUS:CANCELLED\r\n"
    assert calendar =~ "SEQUENCE:3\r\n"
    assert calendar =~ "DTSTART:20270314T130000Z\r\n"
    assert calendar =~ "SUMMARY:Planning\\, roadmap\\; next\\nATTENDEE:evil"
    refute calendar =~ "\r\nATTENDEE:evil"
    assert String.ends_with?(calendar, "END:VCALENDAR\r\n")
  end
end
