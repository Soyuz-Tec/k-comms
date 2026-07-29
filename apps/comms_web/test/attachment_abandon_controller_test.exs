defmodule CommsWeb.AttachmentAbandonControllerTest.FailingStorage do
  @behaviour CommsIntegrations.ObjectStorage

  @impl true
  def presign_upload(_attachment), do: {:error, :object_storage_adapter_not_configured}

  @impl true
  def presign_download(_attachment), do: {:error, :not_used}

  @impl true
  def verify_upload(_attachment), do: {:error, :not_used}

  @impl true
  def presign_variant_upload(_variant), do: {:error, :not_used}

  @impl true
  def presign_variant_download(_variant), do: {:error, :not_used}

  @impl true
  def verify_variant_upload(_variant), do: {:error, :not_used}

  @impl true
  def verify_restored_object(_attachment), do: {:error, :not_used}

  @impl true
  def delete_object(_request), do: {:error, :not_used}

  @impl true
  def purge_object_versions(_request), do: {:error, :not_used}

  @impl true
  def status, do: %{status: :unavailable, adapter: "failing-test"}
end

defmodule CommsWeb.AttachmentAbandonControllerTest do
  use CommsWeb.ConnCase, async: false

  import Ecto.Query

  alias CommsCore.{Attachments, Messaging}
  alias CommsCore.Attachments.Attachment
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  test "DELETE abandons only the owner's unclaimed intent and remains idempotent" do
    account = Fixtures.account_fixture()
    foreign_account = Fixtures.account_fixture()
    pending = pending_attachment(account, "a")

    assert foreign_account
           |> authenticated_conn()
           |> delete("/api/v1/attachments/#{pending.id}")
           |> response(404)

    assert account
           |> authenticated_conn()
           |> delete("/api/v1/attachments/#{pending.id}")
           |> response(204)

    assert account
           |> authenticated_conn()
           |> delete("/api/v1/attachments/#{pending.id}")
           |> response(204)

    assert {:ok, abandoned} =
             Attachments.get_authorized(pending.id, Fixtures.subject(account))

    assert abandoned.status == :deleted
  end

  test "DELETE refuses an attachment already claimed by a message" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    pending = pending_attachment(account, "b")

    assert {:ok, uploaded} =
             Attachments.mark_uploaded(
               pending.id,
               pending.checksum_sha256,
               identity(pending.checksum_sha256),
               subject
             )

    assert {:ok, scanning} = Attachments.claim_scan(uploaded.id)

    assert {:ok, ready} =
             Attachments.record_scan(
               scanning,
               {:ok, %{verdict: :clean, provider: "controller-test"}}
             )

    assert {:ok, _message} =
             Messaging.accept_message(
               %{
                 tenant_id: account.tenant.id,
                 conversation_id: account.conversation.id,
                 sender_user_id: account.user.id,
                 sender_device_id: account.device.id,
                 client_message_id: "claimed-#{System.unique_integer([:positive])}",
                 body: "Claim the attachment",
                 attachment_ids: [ready.id]
               },
               subject
             )

    response =
      account
      |> authenticated_conn()
      |> delete("/api/v1/attachments/#{ready.id}")
      |> json_response(409)

    assert response["error"]["code"] == "attachment_claimed"
  end

  test "presign failure compensates the committed intent into durable cleanup" do
    account = Fixtures.account_fixture()
    previous_adapter = Application.get_env(:comms_integrations, :object_storage_adapter)

    Application.put_env(
      :comms_integrations,
      :object_storage_adapter,
      CommsWeb.AttachmentAbandonControllerTest.FailingStorage
    )

    on_exit(fn ->
      Application.put_env(:comms_integrations, :object_storage_adapter, previous_adapter)
    end)

    checksum = String.duplicate("c", 64)

    response =
      account
      |> authenticated_conn()
      |> post("/api/v1/attachments", %{
        file_name: "presign-failure.txt",
        content_type: "text/plain",
        byte_size: 12,
        checksum_sha256: checksum
      })
      |> json_response(503)

    assert response["error"]["code"] == "provider_unavailable"

    attachment =
      Repo.one!(
        from(attachment in Attachment,
          where:
            attachment.tenant_id == ^account.tenant.id and
              attachment.file_name == "presign-failure.txt"
        )
      )

    assert attachment.status == :deleted
    assert attachment.cleanup_status == :scheduled
    assert is_nil(attachment.upload_expires_at)
    assert %DateTime{} = attachment.cleanup_next_attempt_at
  end

  defp pending_attachment(account, checksum_character) do
    checksum = String.duplicate(checksum_character, 64)

    assert {:ok, attachment} =
             Attachments.create_intent(
               %{
                 file_name: "controller-abandon-#{checksum_character}.txt",
                 content_type: "text/plain",
                 byte_size: 12,
                 checksum_sha256: checksum
               },
               Fixtures.subject(account)
             )

    attachment
  end

  defp identity(checksum) do
    %{
      object_version_id: "version-controller",
      object_etag: "\"etag-controller\"",
      verified_checksum_sha256: checksum
    }
  end

  defp authenticated_conn(account) do
    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    build_conn() |> put_req_header("authorization", "Bearer #{token}")
  end
end
