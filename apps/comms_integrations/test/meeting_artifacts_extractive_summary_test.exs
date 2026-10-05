defmodule CommsIntegrations.MeetingArtifacts.ExtractiveSummaryTest do
  use ExUnit.Case, async: false
  alias CommsCore.AudioCalls.ArtifactSummaryRequest
  alias CommsIntegrations.MeetingArtifacts.ExtractiveSummary

  setup do
    old = Application.fetch_env(:comms_integrations, :artifact_summarization)

    Application.put_env(:comms_integrations, :artifact_summarization,
      enabled: true,
      qualified: true
    )

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(:comms_integrations, :artifact_summarization, value)
        :error -> Application.delete_env(:comms_integrations, :artifact_summarization)
      end
    end)
  end

  test "actual extractive algorithm returns unchanged quotes in source order with exact lineage" do
    text =
      "A first introduction.\nWe agreed to deliver Friday.\nWho will follow up?\nFinal remarks."

    request = %ArtifactSummaryRequest{
      artifact_id: "summary",
      source_artifact_id: "transcript",
      source_sha256: String.duplicate("a", 64),
      text: text,
      deadline: System.monotonic_time(:millisecond) + 1_000
    }

    assert {:ok, receipt} = ExtractiveSummary.summarize(request)
    assert receipt.model == "extractive-quotes-v1"
    assert receipt.source_sha256 == request.source_sha256
    assert String.split(receipt.text, "\n\n") == String.split(text, "\n")
    assert receipt.provider_id == "local-extractive:" <> request.source_sha256
  end

  test "expired budgets, disabled privacy composition and oversized sources produce no content" do
    base = %ArtifactSummaryRequest{
      artifact_id: "summary",
      source_artifact_id: "transcript",
      source_sha256: String.duplicate("a", 64),
      text: "We agreed to deliver.",
      deadline: System.monotonic_time(:millisecond) - 1
    }

    assert {:error, _} = ExtractiveSummary.summarize(base)

    assert {:error, _} =
             ExtractiveSummary.summarize(%{
               base
               | text: String.duplicate("x", 131_073),
                 deadline: System.monotonic_time(:millisecond) + 1_000
             })

    Application.put_env(:comms_integrations, :artifact_summarization,
      enabled: false,
      qualified: true
    )

    refute ExtractiveSummary.configured?()

    assert {:error, _} =
             ExtractiveSummary.summarize(%{
               base
               | deadline: System.monotonic_time(:millisecond) + 1_000
             })
  end
end
