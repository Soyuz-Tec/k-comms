defmodule CommsWeb.InstantRoomCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use CommsWeb.ConnCase, async: false

      import CommsWeb.InstantRoomCase,
        only: [public_json_headers: 1, public_json_headers: 2, idempotency_key: 0, guest_conn: 1]

      setup do
        account = CommsTestSupport.Fixtures.account_fixture()

        settings = %{
          instant_rooms_enabled: true,
          instant_room_tenant_slug: account.tenant.slug,
          instant_room_guest_idle_ttl_seconds: 3_600,
          instant_room_registered_idle_ttl_seconds: 86_400,
          instant_room_presence_heartbeat_seconds: 30,
          instant_room_presence_lease_seconds: 90,
          instant_room_reconnect_grace_seconds: 90,
          instant_room_max_participants: 5
        }

        previous =
          Map.new(settings, fn {key, _value} ->
            {key, Application.get_env(:comms_core, key)}
          end)

        Enum.each(settings, fn {key, value} ->
          Application.put_env(:comms_core, key, value)
        end)

        on_exit(fn ->
          Enum.each(previous, fn {key, value} ->
            if is_nil(value),
              do: Application.delete_env(:comms_core, key),
              else: Application.put_env(:comms_core, key, value)
          end)
        end)

        {:ok, account: account}
      end
    end
  end

  def public_json_headers(conn, idempotency_key \\ nil) do
    conn =
      conn
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("origin", "http://localhost:5173")

    if is_binary(idempotency_key),
      do: Plug.Conn.put_req_header(conn, "idempotency-key", idempotency_key),
      else: conn
  end

  def idempotency_key do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  def guest_conn(token) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
  end
end
