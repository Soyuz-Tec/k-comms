defmodule CommsCore.AudioCalls.MeetingSchedule do
  @moduledoc false
  @maximum_occurrences 52
  @maximum_horizon_seconds 366 * 86_400

  def validate(attrs, observed_at \\ DateTime.utc_now())

  def validate(attrs, observed_at) when is_map(attrs) do
    with title when is_binary(title) <- value(attrs, :title),
         title = String.trim(title),
         true <- String.length(title) in 1..200 and byte_size(title) <= 800,
         zone when is_binary(zone) <- value(attrs, :timezone),
         true <- byte_size(zone) in 1..100,
         {:ok, local_start} <- parse_local(value(attrs, :local_start)),
         duration when is_integer(duration) and duration in 5..480 <-
           value(attrs, :duration_minutes),
         reminder when is_integer(reminder) and reminder in 0..10_080 <-
           value(attrs, :reminder_minutes),
         {:ok, recurrence} <- recurrence(value(attrs, :recurrence)),
         {:ok, policy} <- policy(value(attrs, :host_policy)),
         {:ok, starts} <- occurrences(local_start, zone, recurrence),
         true <- DateTime.diff(hd(starts), observed_at) >= 60,
         true <- DateTime.diff(List.last(starts), observed_at) <= @maximum_horizon_seconds do
      {:ok,
       %{
         title: title,
         timezone: zone,
         local_start: local_start,
         duration_minutes: duration,
         reminder_minutes: reminder,
         recurrence: recurrence,
         host_policy: policy
       },
       Enum.map(starts, fn starts_at ->
         %{
           starts_at: starts_at,
           ends_at: DateTime.add(starts_at, duration * 60),
           reminder_at: DateTime.add(starts_at, -reminder * 60)
         }
       end)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_meeting}
    end
  end

  def validate(_, _), do: {:error, :invalid_meeting}

  def occurrences(local_start, zone, recurrence) do
    count = recurrence["count"]

    days =
      case recurrence["frequency"] do
        "none" -> 0
        "daily" -> recurrence["interval"]
        "weekly" -> 7 * recurrence["interval"]
      end

    Enum.reduce_while(0..(count - 1), {:ok, []}, fn index, {:ok, acc} ->
      local = NaiveDateTime.add(local_start, index * days * 86_400)

      case DateTime.from_naive(local, zone) do
        {:ok, instant} ->
          {:ok, utc} = DateTime.shift_zone(instant, "Etc/UTC")
          {:cont, {:ok, [DateTime.truncate(utc, :microsecond) | acc]}}

        {:ambiguous, _, _} ->
          {:halt, {:error, :ambiguous_meeting_time}}

        {:gap, _, _} ->
          {:halt, {:error, :nonexistent_meeting_time}}

        {:error, _} ->
          {:halt, {:error, :invalid_meeting_timezone}}
      end
    end)
    |> case do
      {:ok, instants} -> {:ok, Enum.reverse(instants)}
      error -> error
    end
  end

  defp parse_local(%NaiveDateTime{} = local), do: {:ok, NaiveDateTime.truncate(local, :second)}

  defp parse_local(local) when is_binary(local) do
    # A wall-clock value deliberately contains no offset; the named zone is authoritative.
    if Regex.match?(~r/^\d{4}-\d\d-\d\dT\d\d:\d\d(:\d\d)?$/, local) do
      case NaiveDateTime.from_iso8601(if byte_size(local) == 16, do: local <> ":00", else: local) do
        {:ok, parsed} -> {:ok, parsed}
        _ -> {:error, :invalid_meeting}
      end
    else
      {:error, :invalid_meeting}
    end
  end

  defp parse_local(_), do: {:error, :invalid_meeting}

  defp recurrence(nil), do: {:ok, %{"frequency" => "none", "interval" => 1, "count" => 1}}

  defp recurrence(attrs) when is_map(attrs) do
    frequency = value(attrs, :frequency)
    interval = value(attrs, :interval) || 1
    count = value(attrs, :count) || 1

    if frequency in ["none", "daily", "weekly"] and is_integer(interval) and interval in 1..4 and
         is_integer(count) and count in 1..@maximum_occurrences and
         (frequency != "none" or count == 1) do
      {:ok, %{"frequency" => frequency, "interval" => interval, "count" => count}}
    else
      {:error, :invalid_meeting_recurrence}
    end
  end

  defp recurrence(_), do: {:error, :invalid_meeting_recurrence}

  defp policy(nil), do: {:ok, %{"allow_guests" => false, "join_before_host" => false}}

  defp policy(attrs) when is_map(attrs) do
    guests = Map.get(attrs, :allow_guests, Map.get(attrs, "allow_guests", false))
    before_host = Map.get(attrs, :join_before_host, Map.get(attrs, "join_before_host", false))

    if is_boolean(guests) and is_boolean(before_host),
      do: {:ok, %{"allow_guests" => guests, "join_before_host" => before_host}},
      else: {:error, :invalid_meeting_host_policy}
  end

  defp policy(_), do: {:error, :invalid_meeting_host_policy}
  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
