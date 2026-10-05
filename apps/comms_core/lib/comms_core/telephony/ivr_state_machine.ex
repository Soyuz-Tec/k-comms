defmodule CommsCore.Telephony.IvrStateMachine do
  @moduledoc "Bounded single-level caller selection; no SIP input confers app authority."

  @terminal [:completed, :failed, :cancelled]
  @target_keys %{
    "hangup" => MapSet.new(["kind"]),
    "route" => MapSet.new(["kind", "route_id"]),
    "voicemail" => MapSet.new(["kind", "mailbox_id"]),
    "destination" => MapSet.new(["kind", "destination"])
  }

  def valid_choices?(choices) when is_map(choices) and map_size(choices) in 1..9 do
    Enum.all?(choices, fn {digit, target} ->
      is_binary(digit) and digit in ~w(1 2 3 4 5 6 7 8 9) and valid_target?(target)
    end)
  end

  def valid_choices?(_), do: false

  def valid_target?(%{"kind" => kind} = target) when is_map(target) do
    MapSet.new(Map.keys(target)) == Map.get(@target_keys, kind) and
      case kind do
        "hangup" -> true
        "route" -> uuid?(target["route_id"])
        "voicemail" -> uuid?(target["mailbox_id"])
        "destination" ->
          is_binary(target["destination"]) and
            Regex.match?(~r/^\+[1-9][0-9]{7,14}$/, target["destination"])
        _ -> false
      end
  end

  def valid_target?(_), do: false

  def playback_id(run_id, step) when is_integer(step) and step in 1..3,
    do: "kc_ivr_" <> String.replace(run_id, "-", "") <> "_" <> Integer.to_string(step)

  def terminal?(phase), do: phase in @terminal

  def playback_completed(run, playback_id, media_uri, now),
    do: playback(run, %{playback_id: playback_id, media_uri: media_uri}, now)

  @doc "Returns persistence attributes; the owner applies them under exact call/run locks."
  def apply(run, event, now) do
    cond do
      terminal?(run.phase) -> {:ignored, %{}}
      DateTime.compare(run.expires_at, now) != :gt -> deadline_failure()
      event.step != run.step -> {:ignored, %{}}
      event.type == :playback_finished -> playback(run, event, now)
      event.type == :digit -> digit(run, event, now)
      true -> {:ignored, %{}}
    end
  end

  def timeout(run, now) do
    cond do
      terminal?(run.phase) -> {:ignored, %{}}
      DateTime.compare(run.expires_at, now) != :gt -> deadline_failure()
      run.phase == :awaiting_digit and DateTime.compare(run.digit_deadline, now) != :gt ->
        retry_or_fallback(run)
      true -> {:wait, %{}}
    end
  end

  defp playback(%{phase: phase} = run, event, now) when phase in [:playing, :unknown] do
    if event.playback_id == playback_id(run.id, run.step) and
         event.media_uri == run.snapshot["prompt_media"] do
      completed_at = Map.get(event, :occurred_at, now)
      deadline = DateTime.add(completed_at, run.snapshot["digit_timeout_seconds"], :second)
      {:applied, %{phase: :awaiting_digit, prompt_completed_at: completed_at,
                   digit_deadline: earliest(deadline, run.expires_at), failure_reason: nil}}
    else
      {:ignored, %{}}
    end
  end

  defp playback(_run, _event, _now), do: {:ignored, %{}}

  defp digit(%{phase: :awaiting_digit} = run, event, now) do
    occurred_at = Map.get(event, :occurred_at, now)
    cond do
      is_nil(run.prompt_completed_at) or DateTime.compare(occurred_at, run.prompt_completed_at) == :lt ->
        {:ignored, %{}}
      DateTime.compare(run.digit_deadline, now) != :gt -> retry_or_fallback(run)
      DateTime.compare(occurred_at, run.digit_deadline) != :lt -> retry_or_fallback(run)
      true ->
        case Map.fetch(run.snapshot["choices"], event.digit) do
          {:ok, target} -> {:applied, %{phase: :selected, selected_target: target}}
          :error -> retry_or_fallback(run)
        end
    end
  end

  defp digit(_run, _event, _now), do: {:ignored, %{}}

  defp retry_or_fallback(run) do
    if run.retries < run.snapshot["max_retries"] do
      {:applied, %{phase: :pending, retries: run.retries + 1, step: run.step + 1,
                   claimed_at: nil, prompt_completed_at: nil, digit_deadline: nil,
                   effect_claim_fingerprint: nil, effect_started_at: nil, failure_reason: nil}}
    else
      select_fallback(run)
    end
  end

  defp select_fallback(run),
    do: {:applied, %{phase: :selected, selected_target: run.snapshot["fallback"]}}

  defp deadline_failure,
    do: {:applied, %{phase: :failed, failure_reason: "ivr_deadline"}}

  defp earliest(left, right), do: if(DateTime.compare(left, right) == :gt, do: right, else: left)
  defp uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
end
