defmodule CommsWeb.IntegrationsSafetyOps.AttachmentRetryTest do
  use CommsWeb.IntegrationSafetyOpsCase

  @moduletag :integration
  @moduletag :integrations
  @moduletag :attachment

  test "attachment safety retries require recent step-up" do
    owner = bootstrap_owner()

    attachment =
      authenticated_conn(owner.token)
      |> post("/api/v1/attachments", %{
        file_name: "retry.txt",
        content_type: "text/plain",
        byte_size: 12,
        checksum_sha256: String.duplicate("b", 64)
      })
      |> json_response(201)

    attachment_id = attachment["data"]["id"]

    authenticated_conn(owner.token)
    |> post("/api/v1/attachments/#{attachment_id}/complete", %{})
    |> json_response(200)

    assert authenticated_conn(owner.token)
           |> post("/api/v1/admin/attachment-safety/#{attachment_id}/retry")
           |> response(428)

    authenticated_conn(owner.token)
    |> post("/api/v1/me/step-up", %{current_password: owner.password})
    |> json_response(200)

    retried =
      authenticated_conn(owner.token)
      |> post("/api/v1/admin/attachment-safety/#{attachment_id}/retry")
      |> json_response(202)

    assert retried["data"]["id"] == attachment_id
  end
end
