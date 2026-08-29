defmodule CommsObservability.PeerLinkMetricsTest do
  use ExUnit.Case, async: false

  alias CommsObservability.Metrics

  setup do
    # The counter table is application-owned and process-independent, so each
    # test clears it rather than starting a second collector.
    if :ets.whereis(Metrics) != :undefined, do: :ets.delete_all_objects(Metrics)
    :ok
  end

  test "renders every peer-link series before any outcome is reported" do
    rendered = Metrics.render()

    assert rendered =~ "k_comms_peer_link_attempts_total 0"

    for class <- Metrics.peer_link_candidate_classes() do
      assert rendered =~ "k_comms_peer_link_connections_total{candidate_class=\"#{class}\"} 0"
    end

    for reason <- Metrics.peer_link_fallback_reasons() do
      assert rendered =~ "k_comms_peer_link_fallbacks_total{reason=\"#{reason}\"} 0"
    end

    assert rendered =~ "k_comms_peer_link_connect_duration_seconds_count 0"
  end

  test "counts admissions, connections by candidate class, and fallbacks by reason" do
    Metrics.record([:peer_link, :attempt], %{count: 1})
    Metrics.record([:peer_link, :attempt], %{count: 1})

    Metrics.record([:peer_link, :connected], %{candidate_class: "relay", duration_seconds: 1.5})

    Metrics.record([:peer_link, :fallback], %{reason: "ice_timeout"})

    rendered = Metrics.render()

    assert rendered =~ "k_comms_peer_link_attempts_total 2"
    assert rendered =~ "k_comms_peer_link_connections_total{candidate_class=\"relay\"} 1"
    assert rendered =~ "k_comms_peer_link_connections_total{candidate_class=\"host\"} 0"
    assert rendered =~ "k_comms_peer_link_fallbacks_total{reason=\"ice_timeout\"} 1"
    assert rendered =~ "k_comms_peer_link_fallbacks_total{reason=\"signaling\"} 0"
    assert rendered =~ "k_comms_peer_link_connect_duration_seconds_count 1"
    assert rendered =~ "k_comms_peer_link_connect_duration_seconds_bucket{le=\"2.0\"} 1"
    assert rendered =~ "k_comms_peer_link_connect_duration_seconds_bucket{le=\"1.0\"} 0"
  end

  test "an identifier outside the closed label set never reaches a rendered label" do
    Metrics.record([:peer_link, :connected], %{
      candidate_class: "tenant-7f3a:user-19",
      duration_seconds: 0.4
    })

    Metrics.record([:peer_link, :fallback], %{reason: "203.0.113.9"})

    rendered = Metrics.render()

    refute rendered =~ "tenant-7f3a"
    refute rendered =~ "203.0.113.9"

    assert rendered
           |> String.split("\n")
           |> Enum.filter(&String.starts_with?(&1, "k_comms_peer_link_connections_total{"))
           |> length() == length(Metrics.peer_link_candidate_classes())

    assert rendered
           |> String.split("\n")
           |> Enum.filter(&String.starts_with?(&1, "k_comms_peer_link_fallbacks_total{"))
           |> length() == length(Metrics.peer_link_fallback_reasons())
  end

  test "a malformed duration does not observe the connect histogram" do
    Metrics.record([:peer_link, :connected], %{candidate_class: "host", duration_seconds: "1.0"})

    rendered = Metrics.render()

    assert rendered =~ "k_comms_peer_link_connections_total{candidate_class=\"host\"} 1"
    assert rendered =~ "k_comms_peer_link_connect_duration_seconds_count 0"
  end
end
