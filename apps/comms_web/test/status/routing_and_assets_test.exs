defmodule CommsWeb.Status.RoutingAndAssetsTest do
  use CommsWeb.StatusCase

  @moduletag :integration
  @moduletag :operations

  test "unknown API routes stay JSON 404s", %{conn: conn} do
    conn = get(conn, "/api/v1/does-not-exist")
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  test "legacy member root redirects into the service-worker scope with its query", %{conn: conn} do
    response =
      get(
        conn,
        "/app?conversation=11111111-1111-4111-8111-111111111111&message=22222222-2222-4222-8222-222222222222"
      )

    assert response(response, 308) == ""

    assert get_resp_header(response, "location") == [
             "/app/?conversation=11111111-1111-4111-8111-111111111111&message=22222222-2222-4222-8222-222222222222"
           ]

    assert get_resp_header(response, "cache-control") == [
             "no-store, max-age=0, must-revalidate"
           ]
  end

  test "SPA fallback serves the built index as HTML", %{conn: conn} do
    index_path = Application.app_dir(:comms_web, "priv/static/app/index.html")
    previous = if File.exists?(index_path), do: File.read!(index_path)

    File.mkdir_p!(Path.dirname(index_path))
    File.write!(index_path, "<!doctype html><title>K-Comms test index</title>")

    on_exit(fn ->
      if previous do
        File.write!(index_path, previous)
      else
        File.rm(index_path)
      end
    end)

    response = get(conn, "/app/workspace")
    entry_response = get(build_conn(), "/app/")

    assert response(response, 200) =~ "K-Comms test index"
    assert response(entry_response, 200) =~ "K-Comms test index"
    assert [content_type] = get_resp_header(response, "content-type")
    assert content_type =~ "text/html"
    assert [entry_content_type] = get_resp_header(entry_response, "content-type")
    assert entry_content_type =~ "text/html"

    assert get_resp_header(entry_response, "cache-control") == [
             "no-store, max-age=0, must-revalidate"
           ]
  end

  test "missing application assets never fall back to cacheable SPA HTML", %{conn: conn} do
    for path <- [
          "/app/assets/missing-A1b2C3d4.js",
          "/app/icons/missing.png",
          "/app/k-comms-sw.js",
          "/app/manifest.webmanifest",
          "/app/offline.css",
          "/app/offline.html"
        ] do
      response = get(conn, path)

      assert response(response, 404) == "Static application asset not found"
      assert [content_type] = get_resp_header(response, "content-type")
      assert content_type =~ "text/plain"

      assert get_resp_header(response, "cache-control") == [
               "no-store, max-age=0, must-revalidate"
             ]
    end
  end
end
