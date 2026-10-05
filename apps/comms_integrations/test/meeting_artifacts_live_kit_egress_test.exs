defmodule CommsIntegrations.MeetingArtifacts.LiveKitEgressTest do
  use ExUnit.Case, async: false

  alias CommsCore.AudioCalls.{ArtifactProviderReceipt, ArtifactProviderRequest}
  alias CommsIntegrations.MeetingArtifacts.LiveKitEgress

  @secret "synthetic-livekit-secret-minimum-32-bytes"

  setup do
    values = %{
      meeting_artifacts_enabled: true,
      egress_enabled: true,
      audio_provider_mode: "livekit",
      livekit_api_url: "https://media.example.test",
      livekit_api_key: "synthetic-api-key",
      livekit_api_secret: @secret,
      object_storage_adapter: CommsIntegrations.ObjectStorage.S3,
      s3: [
        scheme: "https",
        host: "files.example.test",
        port: 443,
        bucket: "approved-bucket",
        region: "us-east-1",
        access_key_id: "synthetic-access-key",
        secret_access_key: "synthetic-storage-secret"
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

  test "disabled recording has no transport side effect" do
    Application.delete_env(:comms_integrations, :meeting_artifacts_enabled)
    refute LiveKitEgress.configured?()

    assert LiveKitEgress.start(command(), fn _, _, _, _, _ -> flunk("disabled recording") end) ==
             {:error, :artifact_provider_unavailable}

    Application.put_env(:comms_integrations, :meeting_artifacts_enabled, true)
    Application.delete_env(:comms_integrations, :egress_enabled)
    refute LiveKitEgress.configured?()
  end

  test "start binds the exact tenant recording key and uses only a short roomRecord grant" do
    requester = fn :post, url, headers, body, options ->
      assert url == "https://media.example.test/twirp/livekit.Egress/StartRoomCompositeEgress"
      decoded = Jason.decode!(body)
      assert decoded["room_name"] == command().provider_room
      assert decoded["audio_only"] == false
      [file] = decoded["file_outputs"]
      assert file["filepath"] == command().object_key
      assert file["disable_manifest"] == true
      assert file["file_type"] == "MP4"
      assert file["s3"]["bucket"] == "approved-bucket"
      assert file["s3"]["endpoint"] == "https://files.example.test"
      assert options[:timeout_ms] == 5_000
      assert options[:max_response_bytes] == 262_144
      assert options[:allowed_hosts] == ["media.example.test"]

      {"authorization", "Bearer " <> token} = List.keyfind(headers, "authorization", 0)
      [_header, payload, _signature] = String.split(token, ".")
      claims = payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
      assert claims["video"] == %{"room" => command().provider_room, "roomRecord" => true}
      assert claims["exp"] <= System.system_time(:second) + 30
      refute Map.has_key?(claims, "sub")
      {:ok, %{status: 200, body: Jason.encode!(info())}}
    end

    assert {:ok, %ArtifactProviderReceipt{provider_job_id: "EG_exact", state: :recording}} =
             LiveKitEgress.start(command(), requester)
  end

  test "unsafe keys, arbitrary maps, and responses for another room fail closed" do
    never = fn _, _, _, _, _ -> flunk("unsafe destination contacted provider") end

    assert LiveKitEgress.start(%{command() | object_key: "tenant/other.mp4"}, never) ==
             {:error, :invalid_artifact_provider_request}

    assert LiveKitEgress.start(Map.from_struct(command()), never) ==
             {:error, :invalid_artifact_provider_request}

    response = %{info() | "roomName" => "other-room"}

    assert LiveKitEgress.start(command(), fn _, _, _, _, _ ->
             {:ok, %{status: 200, body: Jason.encode!(response)}}
           end) == {:error, :artifact_provider_outcome_unknown}
  end

  test "an uncertain start is never retried and reconciliation requires one exact output match" do
    parent = self()

    assert LiveKitEgress.start(command(), fn _, _, _, _, _ ->
             send(parent, :start_attempt)
             {:error, :outbound_timeout}
           end) == {:error, :artifact_provider_outcome_unknown}

    assert_receive :start_attempt
    refute_receive :start_attempt

    requester = fn :post, url, _, body, _ ->
      assert String.ends_with?(url, "/ListEgress")
      assert Jason.decode!(body) == %{"room_name" => command().provider_room}
      {:ok, %{status: 200, body: Jason.encode!(%{items: [reconcilable_info()]})}}
    end

    assert {:ok, %ArtifactProviderReceipt{provider_job_id: "EG_exact"}} =
             LiveKitEgress.reconcile(command(), requester)

    assert LiveKitEgress.reconcile(command(), fn _, _, _, _, _ ->
             {:ok,
              %{
                status: 200,
                body: Jason.encode!(%{items: [reconcilable_info(), reconcilable_info()]})
              }}
           end) == {:error, :artifact_provider_outcome_unknown}

    other =
      put_in(
        reconcilable_info(),
        ["roomComposite", "fileOutputs", Access.at(0), "s3", "bucket"],
        "other-bucket"
      )

    assert LiveKitEgress.reconcile(command(), fn _, _, _, _, _ ->
             {:ok, %{status: 200, body: Jason.encode!(%{items: [other]})}}
           end) == {:error, :artifact_provider_job_not_found}
  end

  test "stop retains control after admissions turn off and binds the exact provider job" do
    Application.put_env(:comms_integrations, :meeting_artifacts_enabled, false)
    Application.put_env(:comms_integrations, :egress_enabled, false)
    command = %{command() | provider_job_id: "EG_exact"}

    assert {:ok, %ArtifactProviderReceipt{state: :processing}} =
             LiveKitEgress.stop(command, fn :post, url, _, body, _ ->
               assert String.ends_with?(url, "/StopEgress")
               assert Jason.decode!(body) == %{"egress_id" => "EG_exact"}
               {:ok, %{status: 200, body: Jason.encode!(info())}}
             end)

    assert LiveKitEgress.stop(command, fn _, _, _, _, _ ->
             {:ok, %{status: 200, body: Jason.encode!(%{info() | "egressId" => "EG_other"})}}
           end) == {:error, :artifact_provider_outcome_unknown}
  end

  test "callback authenticates exact bytes and emits only bound lifecycle and object fields" do
    body = Jason.encode!(callback())
    token = webhook_token(body)

    assert {:ok,
            %{
              event_id: "event-exact",
              event_type: "egress_ended",
              provider_job_id: "EG_exact",
              provider_room: "room-exact",
              state: :available,
              object_key: "tenant/meeting-artifacts/call/artifact.mp4",
              byte_size: 100,
              occurred_at: %DateTime{}
            } = normalized} = LiveKitEgress.verify_callback(body, "Bearer " <> token)

    refute Map.has_key?(normalized, :location)
    refute Map.has_key?(normalized, :tenant_id)

    assert LiveKitEgress.verify_callback(body <> " ", token) ==
             {:error, :invalid_provider_webhook}

    assert LiveKitEgress.verify_callback(body, webhook_token(body, %{"iss" => "wrong-project"})) ==
             {:error, :invalid_provider_webhook}

    assert LiveKitEgress.verify_callback(body, webhook_token(body, %{"sha256" => nil})) ==
             {:error, :invalid_provider_webhook}

    assert LiveKitEgress.verify_callback(body, webhook_token(body, %{"exp" => 1})) ==
             {:error, :invalid_provider_webhook}

    assert LiveKitEgress.authorized_adapter?(LiveKitEgress)
    refute LiveKitEgress.authorized_adapter?(__MODULE__)
  end

  test "completion requires a single concrete artifact file and ignores arbitrary provider URLs" do
    invalid = put_in(callback(), ["egressInfo", "fileResults"], [])
    body = Jason.encode!(invalid)

    assert LiveKitEgress.verify_callback(body, webhook_token(body)) ==
             {:error, :invalid_provider_event}

    invalid =
      put_in(
        callback(),
        ["egressInfo", "fileResults", Access.at(0), "filename"],
        "https://attacker.example/a.mp4"
      )

    body = Jason.encode!(invalid)

    assert LiveKitEgress.verify_callback(body, webhook_token(body)) ==
             {:error, :invalid_provider_event}

    body = Jason.encode!(%{"event" => "participant_joined"})

    assert LiveKitEgress.verify_callback(body, webhook_token(body)) ==
             {:error, :unsupported_provider_event}
  end

  defp command do
    %ArtifactProviderRequest{
      tenant_id: "tenant",
      conversation_id: "conversation",
      call_id: "call",
      artifact_id: "artifact",
      provider_room: "room-exact",
      object_key: "tenant/meeting-artifacts/call/artifact.mp4",
      content_type: "video/mp4",
      operation_key: "operation"
    }
  end

  defp info do
    %{"egressId" => "EG_exact", "roomName" => "room-exact", "status" => "EGRESS_ACTIVE"}
  end

  defp reconcilable_info do
    Map.put(info(), "roomComposite", %{
      "roomName" => "room-exact",
      "fileOutputs" => [
        %{
          "fileType" => "MP4",
          "filepath" => command().object_key,
          "s3" => %{
            "bucket" => "approved-bucket",
            "region" => "us-east-1",
            "endpoint" => "https://files.example.test"
          }
        }
      ]
    })
  end

  defp callback do
    %{
      "id" => "event-exact",
      "event" => "egress_ended",
      "createdAt" => "1720000000",
      "egressInfo" => %{
        "egressId" => "EG_exact",
        "roomName" => "room-exact",
        "status" => "EGRESS_COMPLETE",
        "fileResults" => [
          %{
            "filename" => command().object_key,
            "size" => "100",
            "location" => "https://attacker.example/private"
          }
        ]
      }
    }
  end

  defp webhook_token(body, overrides \\ %{}) do
    claims =
      Map.merge(
        %{
          "iss" => "synthetic-api-key",
          "exp" => System.system_time(:second) + 60,
          "sha256" => Base.encode64(:crypto.hash(:sha256, body))
        },
        overrides
      )

    CommsIntegrations.MeetingArtifacts.LiveKitWebhook.sign(claims, @secret)
  end
end
