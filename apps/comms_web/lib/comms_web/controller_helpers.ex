defmodule CommsWeb.ControllerHelpers do
  import Plug.Conn

  def with_idempotency_key(conn, params) do
    case get_req_header(conn, "idempotency-key") do
      [key] when byte_size(key) > 0 and byte_size(key) <= 200 ->
        Map.put_new(params, "idempotency_key", key)

      _ ->
        params
    end
  end
end
