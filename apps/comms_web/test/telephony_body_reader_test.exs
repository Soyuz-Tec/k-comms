defmodule CommsWeb.TelephonyBodyReaderTest do
  use ExUnit.Case, async: true

  alias CommsWeb.TelephonyBodyReader

  @moduletag :unit
  @moduletag :call

  test "preserves webhook bytes across chunks without decoding or normalizing JSON" do
    body = "{\n  \"event\" : \"room_finished\", \"name\": \"é\"\n}\n"
    conn = Plug.Test.conn(:post, "/api/v1/telephony/livekit/webhook", body)

    assert {:more, first, conn} = TelephonyBodyReader.read(conn, length: 11)
    assert {:ok, rest, conn} = TelephonyBodyReader.read(conn, length: 1_024)
    assert first <> rest == body
    assert conn.private.telephony_webhook_body == body
  end

  test "IVR signatures use bounded exact original bytes across parser chunks" do
    body = "{\n \"type\" : \"ChannelDtmfReceived\", \"digit\" : \"1\"\n}"
    conn = Plug.Test.conn(:post, "/api/v1/telephony/ivr/webhook", body)
    assert {:more, first, conn} = TelephonyBodyReader.read(conn, length: 7)
    assert {:ok, rest, conn} = TelephonyBodyReader.read(conn, length: 1_024)
    assert first <> rest == body
    assert conn.private.telephony_ivr_webhook_body == body

    oversize =
      Plug.Test.conn(:post, "/api/v1/telephony/ivr/webhook", String.duplicate("x", 262_145))

    assert_raise Plug.Parsers.RequestTooLargeError, fn ->
      TelephonyBodyReader.read(oversize, length: 2_000_000)
    end
  end

  test "does not retain authentication bodies or unrelated endpoint bodies" do
    for path <- ["/api/v1/sessions", "/api/v1/telephony/calls"] do
      conn = Plug.Test.conn(:post, path, "{\"password\":\"private\"}")
      assert {:ok, _body, conn} = TelephonyBodyReader.read(conn, [])
      refute Map.has_key?(conn.private, :telephony_webhook_body)
    end
  end

  test "rejects a webhook exceeding the cumulative limit before concatenating another chunk" do
    conn =
      Plug.Test.conn(
        :post,
        "/api/v1/telephony/livekit/webhook",
        String.duplicate("x", 262_145)
      )

    assert {:more, first, conn} = TelephonyBodyReader.read(conn, length: 131_072)
    assert {:more, second, conn} = TelephonyBodyReader.read(conn, length: 131_072)
    assert byte_size(first <> second) == 262_144
    assert byte_size(conn.private.telephony_webhook_body) == 262_144

    assert_raise Plug.Parsers.RequestTooLargeError, fn ->
      TelephonyBodyReader.read(conn, length: 2_000_000)
    end
  end

  test "accepts the exact webhook limit and keeps unrelated request limits unchanged" do
    body = String.duplicate("x", 262_144)
    conn = Plug.Test.conn(:post, "/api/v1/telephony/livekit/webhook", body)
    assert {:ok, ^body, conn} = TelephonyBodyReader.read(conn, length: 2_000_000)
    assert conn.private.telephony_webhook_body == body

    other_body = String.duplicate("x", 300_000)
    conn = Plug.Test.conn(:post, "/api/v1/telephony/calls", other_body)
    assert {:ok, ^other_body, conn} = TelephonyBodyReader.read(conn, length: 2_000_000)
    refute Map.has_key?(conn.private, :telephony_webhook_body)
  end
end
