defmodule CommsWeb.GuestCommunication.ArtifactConsentsTest do
  use CommsWeb.ConnCase, async: false
  import CommsWeb.GuestCommunicationTestSupport
  alias CommsCore.{AudioCalls, RuntimePorts}
  alias CommsCore.AudioCalls.ArtifactProviderReceipt
  alias CommsTestSupport.Fixtures
  @moduletag :integration
  @moduletag :guest
  @moduletag :call
  setup :setup_account
  setup {CommsWeb.GuestCommunicationMediaTestSupport, :setup_livekit}

  defmodule RecordingProvider do
    def configured?(), do: true
    def start(request), do: {:ok, receipt(request, :recording)}
    def stop(request), do: {:ok, receipt(request, :processing)}
    def reconcile(request), do: {:ok, receipt(request, :recording)}
    def verify_callback(_, _), do: {:error, :invalid_provider_webhook}

    defp receipt(request, state),
      do: %ArtifactProviderReceipt{
        provider_job_id: request.provider_job_id || "EG_guest_fixture",
        provider_room: request.provider_room,
        object_key: request.object_key,
        state: state
      }
  end

  test "guest admission must explicitly consent, may withdraw, and cannot manage capture or substitute its scope",
       %{account: account, member_token: member_token} do
    keys = [:meeting_artifact_policy, :artifact_provider_adapter]
    old = Enum.map(keys, &{&1, Application.fetch_env(:comms_core, &1)})

    on_exit(fn ->
      Enum.each(old, fn
        {key, {:ok, value}} -> Application.put_env(:comms_core, key, value)
        {key, :error} -> Application.delete_env(:comms_core, key)
      end)
    end)

    Application.put_env(:comms_core, :meeting_artifact_policy,
      privacy_approved: true,
      provider_qualified: true,
      enabled_tenant_ids: [account.tenant.id]
    )

    Application.put_env(:comms_core, :artifact_provider_adapter, RecordingProvider)
    owner = Fixtures.subject(account)
    conversation_id = account.conversation.id

    link =
      member_conn(member_token)
      |> post("/api/v1/conversations/#{conversation_id}/guest-links", %{
        expires_in_seconds: 900,
        max_uses: 1
      })
      |> json_response(201)

    guest =
      build_conn()
      |> post("/api/v1/guest-sessions", %{
        token: link["token"],
        display_name: "Recording Guest",
        device: %{name: "Consent browser", platform: "test"}
      })
      |> json_response(201)

    {:ok, call, :created} = AudioCalls.start(conversation_id, owner)

    {:ok, _, _} =
      AudioCalls.with_join_authorized(conversation_id, call.id, owner, fn request ->
        {:ok, request.provider_identity}
      end)

    guest_conn(guest["access_token"])
    |> post("/api/v1/guest/conversation/calls/#{call.id}/join")
    |> json_response(200)

    {:ok, artifact} =
      AudioCalls.request_artifact(
        conversation_id,
        call.id,
        %{idempotency_key: "guest-recording-consent"},
        owner
      )

    {:ok, _} = AudioCalls.consent_artifact(conversation_id, call.id, artifact.id, true, owner)

    assert {:error, :recording_consent_required} =
             AudioCalls.start_artifact(conversation_id, call.id, artifact.id, owner)

    prefix = "/api/v1/guest/conversation/calls/#{call.id}/artifacts"

    disclosed =
      guest_conn(guest["access_token"])
      |> get(prefix, %{conversation_id: Ecto.UUID.generate()})
      |> json_response(200)

    assert [%{"id" => id, "my_consent" => false, "can_manage" => false}] = disclosed["data"]
    assert id == artifact.id
    refute disclosed["capabilities"]["recording"]

    consent =
      guest_conn(guest["access_token"])
      |> post(
        prefix <> "/#{artifact.id}/consent",
        %{accepted: true, conversation_id: Ecto.UUID.generate(), user_id: account.user.id}
      )
      |> json_response(200)

    assert consent["data"]["my_consent"] == true
    refute consent["data"]["can_manage"]
    {:ok, _} = AudioCalls.start_artifact(conversation_id, call.id, artifact.id, owner)
    {:ok, _} = AudioCalls.process_artifact(artifact.id, RuntimePorts.job_worker!(:call_artifact))

    stopped =
      guest_conn(guest["access_token"])
      |> post(prefix <> "/#{artifact.id}/consent", %{accepted: false})
      |> json_response(200)

    assert stopped["data"]["status"] == "stopping"
    refute stopped["data"]["my_consent"]

    rejected =
      guest_conn(guest["access_token"])
      |> post(prefix <> "/#{Ecto.UUID.generate()}/consent", %{accepted: true})
      |> json_response(404)

    assert rejected["error"]["code"] == "not_found"

    wrong_call =
      guest_conn(guest["access_token"])
      |> get("/api/v1/guest/conversation/calls/#{Ecto.UUID.generate()}/artifacts")
      |> json_response(404)

    assert wrong_call["error"]["code"] == "not_found"
    {:ok, %{context: context}} = CommsWeb.GuestToken.verify(guest["access_token"], "test-request")

    guest_subject =
      Map.merge(context.subject, %{account_type: :guest, guest_conversation_id: conversation_id})

    assert {:error, :forbidden} =
             AudioCalls.start_artifact(conversation_id, call.id, artifact.id, guest_subject)

    assert {:error, :forbidden} =
             AudioCalls.artifact_playback(conversation_id, call.id, artifact.id, guest_subject)

    assert {:error, :forbidden} =
             AudioCalls.artifact_transcript(conversation_id, call.id, artifact.id, guest_subject)

    assert {:error, :forbidden} =
             AudioCalls.list_artifacts(Ecto.UUID.generate(), call.id, guest_subject)
  end
end
