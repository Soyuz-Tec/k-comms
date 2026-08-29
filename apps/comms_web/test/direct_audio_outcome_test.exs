defmodule CommsWeb.DirectAudioOutcomeTest do
  use ExUnit.Case, async: true

  alias CommsObservability.Metrics
  alias CommsWeb.DirectAudioOutcome

  test "accepts a connected outcome for every candidate class" do
    for class <- DirectAudioOutcome.candidate_classes() do
      assert {:ok, %{result: :connected, candidate_class: ^class, connect_ms: 1_250}} =
               DirectAudioOutcome.validate(%{
                 "result" => "connected",
                 "candidate_class" => class,
                 "connect_ms" => 1_250
               })
    end
  end

  test "accepts a fallback outcome for every reason class" do
    for reason <- DirectAudioOutcome.fallback_reasons() do
      assert {:ok, %{result: :fallback, reason: ^reason}} =
               DirectAudioOutcome.validate(%{"result" => "fallback", "reason" => reason})
    end
  end

  test "rejects unknown classes, unknown reasons, and free text" do
    invalid = [
      %{"result" => "connected", "candidate_class" => "tcp", "connect_ms" => 10},
      %{"result" => "connected", "candidate_class" => "user-19", "connect_ms" => 10},
      %{"result" => "fallback", "reason" => "203.0.113.9"},
      %{"result" => "fallback", "reason" => "other"},
      %{"result" => "declined"},
      %{}
    ]

    for outcome <- invalid do
      assert {:error, :invalid_outcome} = DirectAudioOutcome.validate(outcome)
    end
  end

  test "rejects an extra field, a missing field, and an out-of-range connect time" do
    invalid = [
      %{"result" => "connected", "candidate_class" => "relay", "connect_ms" => 10, "ip" => "x"},
      %{"result" => "fallback", "reason" => "declined", "detail" => "x"},
      %{"result" => "connected", "candidate_class" => "relay"},
      %{"result" => "connected", "candidate_class" => "relay", "connect_ms" => -1},
      %{"result" => "connected", "candidate_class" => "relay", "connect_ms" => 60_001},
      %{"result" => "connected", "candidate_class" => "relay", "connect_ms" => "900"}
    ]

    for outcome <- invalid do
      assert {:error, :invalid_outcome} = DirectAudioOutcome.validate(outcome)
    end
  end

  test "the protocol enumerations match the closed metric label sets" do
    assert DirectAudioOutcome.candidate_classes() == Metrics.peer_link_candidate_classes()
    assert DirectAudioOutcome.fallback_reasons() == Metrics.peer_link_fallback_reasons()
  end
end
