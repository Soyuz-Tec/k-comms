defmodule CommsWeb.AuditExportControllerTest do
  use CommsWeb.ConnCase, async: false

  alias CommsCore.Audit

  test "authorized export downloads bounded CSV and records disposition metadata" do
    suffix = System.unique_integer([:positive, :monotonic])
    password = "correct-horse-audit-export-#{suffix}"

    bootstrap =
      build_conn()
      |> post("/api/v1/bootstrap", %{
        tenant_name: "Audit Export #{suffix}",
        tenant_slug: "audit-export-#{suffix}",
        display_name: "Audit Owner",
        email: "audit-owner-#{suffix}@example.test",
        password: password
      })
      |> json_response(201)

    token = bootstrap["access_token"]

    assert authenticated_conn(token)
           |> post("/api/v1/admin/audit-events/export", %{})
           |> response(428)

    authenticated_conn(token)
    |> post("/api/v1/me/step-up", %{current_password: password})
    |> json_response(200)

    assert {:ok, _event} =
             Audit.record(%{
               tenant_id: bootstrap["tenant"]["id"],
               actor_user_id: bootstrap["user"]["id"],
               action: "=CMD()",
               resource_type: "+spreadsheet",
               resource_id: Ecto.UUID.generate(),
               request_id: "@request",
               metadata: %{}
             })

    conn =
      authenticated_conn(token)
      |> post("/api/v1/admin/audit-events/export", %{action: "=CMD()", limit: 10})

    assert response(conn, 200) =~ "\"'=CMD()\""
    assert get_resp_header(conn, "content-type") == ["text/csv; charset=utf-8"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~r/^attachment; filename="k-comms-audit-[0-9TZ]+\.csv"$/
    assert get_resp_header(conn, "x-export-row-count") == ["1"]
    assert get_resp_header(conn, "x-export-truncated") == ["false"]
  end

  defp authenticated_conn(token),
    do: build_conn() |> put_req_header("authorization", "Bearer #{token}")
end
