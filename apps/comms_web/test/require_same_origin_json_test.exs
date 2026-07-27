defmodule CommsWeb.RequireSameOriginJSONTest do
  use CommsWeb.ConnCase, async: false

  test "accepts only the configured public and development JSON origins", %{conn: conn} do
    for origin <- ["http://localhost:5173", "http://127.0.0.1:5173"] do
      accepted =
        conn
        |> put_req_header("content-type", "application/json; charset=utf-8")
        |> put_req_header("origin", origin)
        |> CommsWeb.Plugs.RequireSameOriginJSON.call([])

      refute accepted.halted
    end
  end

  test "does not trust a request Host-derived origin", %{conn: conn} do
    rejected =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", "http://www.example.com")
      |> CommsWeb.Plugs.RequireSameOriginJSON.call([])

    assert rejected.status == 403
    assert Jason.decode!(rejected.resp_body)["error"]["code"] == "untrusted_origin"
  end

  test "rejects missing or foreign origins and non-JSON bodies", %{conn: conn} do
    missing_origin =
      conn
      |> put_req_header("content-type", "application/json")
      |> CommsWeb.Plugs.RequireSameOriginJSON.call([])

    assert missing_origin.status == 403
    assert Jason.decode!(missing_origin.resp_body)["error"]["code"] == "origin_required"

    foreign =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", "https://attacker.example")
      |> CommsWeb.Plugs.RequireSameOriginJSON.call([])

    assert foreign.status == 403
    assert Jason.decode!(foreign.resp_body)["error"]["code"] == "untrusted_origin"

    form =
      build_conn()
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("origin", "http://www.example.com")
      |> CommsWeb.Plugs.RequireSameOriginJSON.call([])

    assert form.status == 415
    assert Jason.decode!(form.resp_body)["error"]["code"] == "unsupported_content_type"
  end
end
