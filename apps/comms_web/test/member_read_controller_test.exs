defmodule CommsWeb.MemberReadControllerTest do
  use CommsWeb.ConnCase, async: false

  alias CommsCore.{Attachments, AudioCalls, Messaging}
  alias CommsTestSupport.Fixtures

  test "directory is tenant-bounded and exposes only the minimal person projection" do
    account = Fixtures.account_fixture()
    visible = Fixtures.user_fixture(account, %{display_name: "Ada Member"}).user
    _foreign = Fixtures.account_fixture(%{display_name: "Foreign Owner"})

    response =
      account
      |> authenticated_conn()
      |> get("/api/v1/directory/users?q=ada&limit=1")
      |> json_response(200)

    assert response == %{
             "data" => [
               %{
                 "id" => visible.id,
                 "display_name" => "Ada Member"
               }
             ],
             "page" => %{"next_cursor" => nil}
           }
  end

  test "direct conversation creation is idempotent and reports the correct status" do
    account = Fixtures.account_fixture()
    other_user = Fixtures.user_fixture(account, %{display_name: "Direct Member"}).user

    created =
      account
      |> authenticated_conn()
      |> post("/api/v1/direct-conversations", %{user_id: other_user.id})
      |> json_response(201)

    assert created["created"] == true
    assert created["data"]["kind"] == "direct"
    assert created["data"]["title"] == nil
    assert created["data"]["counterpart_display_name"] == "Direct Member"

    listed =
      account
      |> authenticated_conn()
      |> get("/api/v1/conversations")
      |> json_response(200)

    assert %{"counterpart_display_name" => "Direct Member", "title" => nil} =
             Enum.find(listed["data"], &(&1["id"] == created["data"]["id"]))

    shown =
      account
      |> authenticated_conn()
      |> get("/api/v1/conversations/#{created["data"]["id"]}")
      |> json_response(200)

    assert shown["data"]["counterpart_display_name"] == "Direct Member"
    assert shown["data"]["title"] == nil

    existing =
      account
      |> authenticated_conn()
      |> post("/api/v1/direct-conversations", %{user_id: other_user.id})
      |> json_response(200)

    assert existing["created"] == false
    assert existing["data"]["id"] == created["data"]["id"]
    assert existing["data"]["counterpart_display_name"] == "Direct Member"

    missing =
      account
      |> authenticated_conn()
      |> post("/api/v1/direct-conversations", %{})
      |> json_response(422)

    assert missing["error"]["code"] == "missing_fields"
  end

  test "files are paginated and redact storage identity and checksum data" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    attachment = ready_attachment(account, "a")

    assert {:ok, message} =
             Messaging.accept_message(
               %{
                 tenant_id: account.tenant.id,
                 conversation_id: account.conversation.id,
                 sender_user_id: account.user.id,
                 sender_device_id: account.device.id,
                 client_message_id: "member-file-controller-test",
                 body: "Shared file",
                 attachment_ids: [attachment.id]
               },
               subject
             )

    response =
      account
      |> authenticated_conn()
      |> get("/api/v1/files?scope=shared_by_me&limit=1")
      |> json_response(200)

    assert response["page"] == %{
             "limit" => 1,
             "has_more" => false,
             "next_cursor" => nil
           }

    assert [file] = response["data"]

    assert Map.keys(file) |> Enum.sort() ==
             ~w(byte_size content_type conversation_id conversation_sequence downloadable file_name id inserted_at message_id owner_user_id safety_state scan_status shared_at status updated_at uploaded_at)

    assert file["id"] == attachment.id
    assert file["message_id"] == message.id
    assert file["conversation_id"] == account.conversation.id
    assert file["downloadable"] == true
    refute Map.has_key?(file, "checksum_sha256")
    refute Map.has_key?(file, "object_key")
    refute Map.has_key?(file, "object_version_id")

    invalid =
      account
      |> authenticated_conn()
      |> get("/api/v1/files?scope=unknown")
      |> json_response(422)

    assert invalid["error"]["code"] == "invalid_file_scope"
  end

  test "calls expose truthful room-session facts without provider credentials" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, call, :created} =
             AudioCalls.start(account.conversation.id, subject, :video)

    response =
      account
      |> authenticated_conn()
      |> get("/api/v1/calls?scope=active&media_kind=video&limit=1000")
      |> json_response(200)

    assert response["page"]["limit"] == 100
    assert response["page"]["has_more"] == false
    assert [session] = response["data"]

    assert Map.keys(session) |> Enum.sort() ==
             ~w(can_end conversation_id duration_seconds end_reason ended_at ended_by_user_id expires_at id media_kind started_at started_by_user_id status)

    assert session["id"] == call.id
    assert session["conversation_id"] == account.conversation.id
    assert session["media_kind"] == "video"
    assert session["status"] == "active"
    assert session["can_end"] == true
    assert is_integer(session["duration_seconds"])
    refute Map.has_key?(session, "tenant_id")
    refute Map.has_key?(session, "provider_room")
    refute Map.has_key?(session, "participant_token")

    invalid =
      account
      |> authenticated_conn()
      |> get("/api/v1/calls?scope=missed")
      |> json_response(422)

    assert invalid["error"]["code"] == "invalid_call_scope"
  end

  test "member read endpoints require a human session" do
    assert build_conn() |> get("/api/v1/directory/users") |> response(401)
    assert build_conn() |> get("/api/v1/files") |> response(401)
    assert build_conn() |> get("/api/v1/calls") |> response(401)
    assert build_conn() |> post("/api/v1/direct-conversations", %{}) |> response(401)
  end

  defp authenticated_conn(account) do
    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    build_conn() |> put_req_header("authorization", "Bearer #{token}")
  end

  defp ready_attachment(account, checksum_character) do
    subject = Fixtures.subject(account)
    checksum = String.duplicate(checksum_character, 64)

    assert {:ok, pending} =
             Attachments.create_intent(
               %{
                 file_name: "member-file-#{checksum_character}.txt",
                 content_type: "text/plain",
                 byte_size: 12,
                 checksum_sha256: checksum
               },
               subject
             )

    assert {:ok, uploaded} =
             Attachments.mark_uploaded(
               pending.id,
               checksum,
               %{
                 object_version_id: "version-#{checksum_character}",
                 object_etag: "etag-#{checksum_character}",
                 verified_checksum_sha256: checksum
               },
               subject
             )

    assert {:ok, scanning} = Attachments.claim_scan(uploaded.id)

    assert {:ok, ready} =
             Attachments.record_scan(
               scanning,
               {:ok, %{verdict: :clean, provider: "controller-test"}}
             )

    ready
  end
end
