defmodule CommsIntegrations.MeetingArtifacts.WhisperTranscriptionTest do
  use ExUnit.Case, async: false

  alias CommsCore.AudioCalls.{
    ArtifactStorageObject,
    ArtifactTranscript,
    ArtifactTranscriptSegment,
    ArtifactTranscriptionRequest
  }

  alias CommsIntegrations.MeetingArtifacts.WhisperTranscription

  @media "synthetic-recording-bytes"
  @checksum :crypto.hash(:sha256, @media) |> Base.encode16(case: :lower)

  setup do
    values = %{
      artifact_transcription: [
        enabled: true,
        qualified: true,
        origin: "https://transcribe.example.test"
      ],
      object_storage_adapter: CommsIntegrations.ObjectStorage.S3,
      s3: [
        scheme: "https",
        host: "files.example.test",
        port: 443,
        bucket: "approved-bucket",
        region: "us-east-1",
        access_key_id: "synthetic-key",
        secret_access_key: "synthetic-secret"
      ]
    }

    previous =
      Map.new(values, fn {key, _} -> {key, Application.fetch_env(:comms_integrations, key)} end)

    Enum.each(values, fn {key, value} -> Application.put_env(:comms_integrations, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:comms_integrations, key, value)
        {key, :error} -> Application.delete_env(:comms_integrations, key)
      end)
    end)
  end

  test "disabled or unqualified transcription neither fetches nor sends a recording" do
    for options <- [
          [],
          [enabled: true, qualified: false, origin: "https://transcribe.example.test"]
        ] do
      Application.put_env(:comms_integrations, :artifact_transcription, options)
      refute WhisperTranscription.configured?()

      assert WhisperTranscription.transcribe(command(), never_requester(), never_fetcher()) ==
               {:error, :artifact_transcription_unavailable}
    end
  end

  test "a version-pinned verified recording is sent only to the qualified fixed multipart endpoint" do
    requester = fn :post, url, headers, body, options ->
      assert url == "https://transcribe.example.test/v1/audio/transcriptions"
      {"content-type", content_type} = List.keyfind(headers, "content-type", 0)
      assert String.starts_with?(content_type, "multipart/form-data; boundary=kc-")
      assert String.contains?(body, "name=\"model\"\r\n\r\nwhisper-1\r\n")
      assert String.contains?(body, "name=\"response_format\"\r\n\r\nverbose_json\r\n")
      assert String.contains?(body, "filename=\"recording.mp4\"")
      assert String.contains?(body, @media)
      refute String.contains?(body, "tenant-exact")
      refute String.contains?(body, "source-exact")
      assert options[:allowed_hosts] == ["transcribe.example.test"]
      assert options[:allowed_ports] == [443]
      assert options[:timeout_ms] == 30_000
      assert options[:max_response_bytes] == 1_048_576
      {:ok, %{status: 200, body: Jason.encode!(response())}}
    end

    fetcher = fn object, config ->
      assert object.object_version_id == "version-exact"
      assert object.verified_checksum_sha256 == @checksum
      assert config.max_media_bytes == 26_214_400
      {:ok, @media}
    end

    assert {:ok,
            %ArtifactTranscript{
              language: "english",
              segments: [
                %ArtifactTranscriptSegment{
                  sequence: 0,
                  start_ms: 250,
                  end_ms: 1_750,
                  text: "Hello."
                },
                %ArtifactTranscriptSegment{
                  sequence: 1,
                  start_ms: 1_750,
                  end_ms: 3_000,
                  text: "Follow up tomorrow."
                }
              ]
            }} = WhisperTranscription.transcribe(command(), requester, fetcher)

    assert WhisperTranscription.authorized_adapter?(WhisperTranscription)
    refute WhisperTranscription.authorized_adapter?(__MODULE__)
  end

  test "tenant/source mismatches, unverified media and oversized captures never fetch or send" do
    changes = [
      %{command() | tenant_id: "other-tenant"},
      %{command() | source_artifact_id: "other-source"},
      %{command() | object: %{command().object | object_version_id: nil}},
      %{command() | object: %{command().object | verified_checksum_sha256: nil}},
      %{command() | object: %{command().object | byte_size: 26_214_401}}
    ]

    for changed <- changes do
      assert WhisperTranscription.transcribe(changed, never_requester(), never_fetcher()) ==
               {:error, :invalid_artifact_transcription_request}
    end

    assert WhisperTranscription.transcribe(
             Map.from_struct(command()),
             never_requester(),
             never_fetcher()
           ) ==
             {:error, :invalid_artifact_transcription_request}
  end

  test "fetched bytes must match the approved version size and full SHA256 before remote send" do
    assert WhisperTranscription.transcribe(command(), never_requester(), fn _, _ ->
             {:ok, String.duplicate("x", byte_size(@media))}
           end) == {:error, :artifact_source_media_unavailable}

    assert WhisperTranscription.transcribe(command(), never_requester(), fn _, _ ->
             {:ok, @media <> "extra"}
           end) == {:error, :artifact_source_media_unavailable}
  end

  test "unsafe configured origins cannot route source bytes" do
    for origin <- [
          "http://transcribe.example.test",
          "https://secret@transcribe.example.test",
          "https://transcribe.example.test/arbitrary",
          "https://transcribe.example.test?target=other",
          "https://127.0.0.1"
        ] do
      Application.put_env(:comms_integrations, :artifact_transcription,
        enabled: true,
        qualified: true,
        origin: origin
      )

      refute WhisperTranscription.configured?()

      assert WhisperTranscription.transcribe(command(), never_requester(), never_fetcher()) ==
               {:error, :artifact_transcription_unavailable}
    end
  end

  test "provider timeouts and oversized responses expose only a bounded failure" do
    assert WhisperTranscription.transcribe(
             command(),
             fn _, _, _, _, _ -> {:error, :outbound_timeout} end,
             media_fetcher()
           ) == {:error, :artifact_transcription_unavailable}

    assert WhisperTranscription.transcribe(
             command(),
             fn _, _, _, _, _ ->
               {:ok, %{status: 200, body: String.duplicate("x", 1_048_577)}}
             end,
             media_fetcher()
           ) == {:error, :artifact_transcription_unavailable}
  end

  test "malformed segment timelines, unsafe text and unsupported response shapes fail closed" do
    invalid_responses = [
      %{"text" => "provider lacks segment evidence"},
      %{"segments" => []},
      put_in(response(), ["segments", Access.at(0), "end"], 0.1),
      put_in(response(), ["segments", Access.at(1), "start"], 0.0),
      put_in(response(), ["segments", Access.at(0), "text"], "unsafe\u0000text"),
      put_in(response(), ["segments", Access.at(0), "start"], "0.25"),
      put_in(response(), ["segments", Access.at(0), "end"], 100_000)
    ]

    for invalid <- invalid_responses do
      assert WhisperTranscription.transcribe(
               command(),
               fn _, _, _, _, _ ->
                 {:ok, %{status: 200, body: Jason.encode!(invalid)}}
               end,
               media_fetcher()
             ) == {:error, :invalid_artifact_transcript}
    end
  end

  defp command do
    %ArtifactTranscriptionRequest{
      tenant_id: "tenant-exact",
      artifact_id: "transcript-exact",
      source_artifact_id: "source-exact",
      object: %ArtifactStorageObject{
        tenant_id: "tenant-exact",
        object_key: "tenant-exact/meeting-artifacts/call-exact/source-exact.mp4",
        object_version_id: "version-exact",
        checksum_sha256: @checksum,
        verified_checksum_sha256: @checksum,
        byte_size: byte_size(@media),
        content_type: "video/mp4"
      }
    }
  end

  defp response do
    %{
      "language" => "english",
      "segments" => [
        %{"id" => 12, "start" => 0.25, "end" => 1.75, "text" => " Hello. "},
        %{"id" => 99, "start" => 1.75, "end" => 3, "text" => "Follow up tomorrow."}
      ]
    }
  end

  defp never_requester, do: fn _, _, _, _, _ -> flunk("unapproved transcription send") end
  defp never_fetcher, do: fn _, _ -> flunk("unapproved recording fetch") end
  defp media_fetcher, do: fn _, _ -> {:ok, @media} end
end
