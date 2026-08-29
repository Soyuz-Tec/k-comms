defmodule CommsWeb.DirectAudioOutcome do
  @moduledoc """
  Validates the single transport outcome a client reports for one peer-link
  attempt.

  The report exists so the direct path can be measured without retaining it.
  Every field is a closed enumeration or a bounded integer, so an outcome
  carries no participant, device, session, address, or session-description
  information and cannot widen metric cardinality.
  """

  @candidate_classes ["host", "srflx", "relay"]
  @fallback_reasons [
    "ice_timeout",
    "signaling",
    "declined",
    "ineligible",
    "duplicate_connection",
    "moderation"
  ]
  @max_connect_milliseconds 60_000

  def candidate_classes, do: @candidate_classes
  def fallback_reasons, do: @fallback_reasons

  def validate(
        %{"result" => "connected", "candidate_class" => class, "connect_ms" => milliseconds} =
          outcome
      )
      when map_size(outcome) == 3 and class in @candidate_classes and is_integer(milliseconds) and
             milliseconds in 0..@max_connect_milliseconds do
    {:ok, %{result: :connected, candidate_class: class, connect_ms: milliseconds}}
  end

  def validate(%{"result" => "fallback", "reason" => reason} = outcome)
      when map_size(outcome) == 2 and reason in @fallback_reasons do
    {:ok, %{result: :fallback, reason: reason}}
  end

  def validate(_outcome), do: {:error, :invalid_outcome}
end
