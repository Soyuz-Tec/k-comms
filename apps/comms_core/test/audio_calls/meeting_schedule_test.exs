defmodule CommsCore.AudioCalls.MeetingScheduleTest do
  use ExUnit.Case, async: true
  alias CommsCore.AudioCalls.MeetingSchedule

  test "weekly local wall-clock recurrence follows DST rather than adding UTC weeks" do
    attrs =
      attrs("2027-03-07T09:00:00", "America/New_York", %{
        "frequency" => "weekly",
        "interval" => 1,
        "count" => 3
      })

    assert {:ok, _, [first, second, third]} =
             MeetingSchedule.validate(attrs, ~U[2027-01-01 00:00:00Z])

    assert first.starts_at == ~U[2027-03-07 14:00:00Z]
    assert second.starts_at == ~U[2027-03-14 13:00:00Z]
    assert third.starts_at == ~U[2027-03-21 13:00:00Z]
    assert DateTime.diff(second.ends_at, second.starts_at) == 3_600
  end

  test "DST gaps and ambiguous wall-clock times reject the complete series" do
    assert {:error, :nonexistent_meeting_time} =
             MeetingSchedule.validate(
               attrs("2027-03-14T02:30:00", "America/New_York"),
               ~U[2027-01-01 00:00:00Z]
             )

    assert {:error, :ambiguous_meeting_time} =
             MeetingSchedule.validate(
               attrs("2027-11-07T01:30:00", "America/New_York"),
               ~U[2027-01-01 00:00:00Z]
             )

    assert {:error, :invalid_meeting_timezone} =
             MeetingSchedule.validate(
               attrs("2027-01-08T09:00:00", "Made/Up"),
               ~U[2027-01-01 00:00:00Z]
             )
  end

  test "recurrence, duration, wall-clock syntax and one-year horizon stay bounded" do
    for recurrence <- [
          %{"frequency" => "weekly", "interval" => 5, "count" => 2},
          %{"frequency" => "daily", "interval" => 1, "count" => 53},
          %{"frequency" => "monthly", "interval" => 1, "count" => 2}
        ] do
      assert {:error, :invalid_meeting_recurrence} =
               MeetingSchedule.validate(
                 attrs("2027-01-08T09:00:00", "Etc/UTC", recurrence),
                 ~U[2027-01-01 00:00:00Z]
               )
    end

    assert {:error, :invalid_meeting} =
             MeetingSchedule.validate(
               attrs("2027-01-08T09:00:00Z", "Etc/UTC"),
               ~U[2027-01-01 00:00:00Z]
             )

    assert {:error, :invalid_meeting} =
             MeetingSchedule.validate(
               attrs("2028-02-08T09:00:00", "Etc/UTC"),
               ~U[2027-01-01 00:00:00Z]
             )
  end

  defp attrs(local_start, timezone, recurrence \\ nil),
    do: %{
      title: "Planning",
      timezone: timezone,
      local_start: local_start,
      duration_minutes: 60,
      reminder_minutes: 10,
      recurrence: recurrence,
      host_policy: %{allow_guests: false, join_before_host: false}
    }
end
