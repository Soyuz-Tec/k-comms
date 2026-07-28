defmodule CommsWeb.Plugs.StaticCacheHeadersTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias CommsWeb.Plugs.StaticCacheHeaders

  test "prevents intermediaries from caching the application entry document" do
    for path <- ["/app/", "/app/?vsn=release", "/app/index.html?vsn=release"] do
      conn =
        conn(:get, path)
        |> StaticCacheHeaders.call([])
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> put_resp_content_type("text/html")
        |> send_resp(200, "")

      assert get_resp_header(conn, "cache-control") == [
               "no-store, max-age=0, must-revalidate"
             ]
    end
  end

  test "prevents intermediaries from caching the service worker" do
    conn =
      conn(:get, "/app/k-comms-sw.js")
      |> StaticCacheHeaders.call([])
      |> put_resp_header("cache-control", "public")
      |> put_resp_content_type("text/javascript")
      |> send_resp(200, "")

    assert get_resp_header(conn, "cache-control") == [
             "no-store, max-age=0, must-revalidate"
           ]

    assert get_resp_header(conn, "service-worker-allowed") == ["/app/"]
  end

  test "requires manifest revalidation and makes hashed assets immutable" do
    manifest =
      conn(:get, "/app/manifest.webmanifest")
      |> StaticCacheHeaders.call([])
      |> put_resp_header("cache-control", "public")
      |> put_resp_content_type("application/manifest+json")
      |> send_resp(200, "")

    asset =
      conn(:get, "/app/assets/index-Cd4dX9E7.js")
      |> StaticCacheHeaders.call([])
      |> put_resp_header("cache-control", "public")
      |> put_resp_content_type("text/javascript")
      |> send_resp(200, "")

    assert get_resp_header(manifest, "cache-control") == [
             "no-cache, max-age=0, must-revalidate"
           ]

    assert get_resp_header(asset, "cache-control") == [
             "public, max-age=31536000, immutable"
           ]
  end

  test "never marks a hash-shaped fallback response immutable" do
    fallback =
      conn(:get, "/app/assets/missing-A1b2C3d4.js")
      |> StaticCacheHeaders.call([])
      |> put_resp_header("cache-control", "public")
      |> put_resp_content_type("text/html")
      |> send_resp(200, "<!doctype html>")

    assert get_resp_header(fallback, "cache-control") == [
             "no-store, max-age=0, must-revalidate"
           ]
  end

  test "does not assign static cache policy to dynamic or unhashed paths" do
    for path <- [
          "/api/v1/messages",
          "/app/offline.html",
          "/app/assets/index.js",
          "/app/assets/index-prod.js",
          "/join"
        ] do
      conn =
        conn(:get, path)
        |> put_resp_header("cache-control", "private, no-store")
        |> StaticCacheHeaders.call([])
        |> send_resp(200, "")

      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert get_resp_header(conn, "service-worker-allowed") == []
    end
  end
end
