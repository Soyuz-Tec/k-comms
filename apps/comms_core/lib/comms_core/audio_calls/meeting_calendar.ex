defmodule CommsCore.AudioCalls.MeetingCalendar do
  @moduledoc false
  alias CommsCore.AudioCalls.MeetingView

  def render(%MeetingView{} = meeting) do
    # One UTC VEVENT per occurrence avoids calendar-provider recurrence/DST divergence.
    events =
      Enum.flat_map(meeting.occurrences, fn occurrence ->
        [
          "BEGIN:VEVENT",
          "UID:#{meeting.id}-#{occurrence.sequence}@k-comms",
          "DTSTAMP:#{stamp(DateTime.utc_now())}",
          "SEQUENCE:#{meeting.version}",
          "DTSTART:#{stamp(occurrence.starts_at)}",
          "DTEND:#{stamp(occurrence.ends_at)}",
          "SUMMARY:#{escape(meeting.title)}",
          "STATUS:#{if meeting.status == :cancelled or Map.get(occurrence, :status) == :cancelled, do: "CANCELLED", else: "CONFIRMED"}",
          "DESCRIPTION:#{escape("K-Comms meeting. Open the authenticated workspace meeting calendar to join. Timezone: #{meeting.timezone}.")}",
          "X-K-COMMS-MEETING-ID:#{meeting.id}",
          "END:VEVENT"
        ]
      end)

    ([
       "BEGIN:VCALENDAR",
       "VERSION:2.0",
       "PRODID:-//K-Comms//Meetings//EN",
       "CALSCALE:GREGORIAN",
       "METHOD:#{if meeting.status == :cancelled, do: "CANCEL", else: "PUBLISH"}"
     ] ++ events ++ ["END:VCALENDAR"])
    |> Enum.map(&fold/1)
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n")
  end

  defp stamp(datetime), do: Calendar.strftime(datetime, "%Y%m%dT%H%M%SZ")

  defp escape(text),
    do:
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("\r\n", "\\n")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\n")
      |> String.replace(";", "\\;")
      |> String.replace(",", "\\,")

  defp fold(line), do: fold(String.codepoints(line), [], "", 0)
  defp fold([], acc, current, _bytes), do: Enum.reverse([current | acc]) |> Enum.join("\r\n ")

  defp fold([part | rest], acc, current, bytes) do
    if bytes + byte_size(part) > 74,
      do: fold(rest, [current | acc], part, byte_size(part)),
      else: fold(rest, acc, current <> part, bytes + byte_size(part))
  end
end
