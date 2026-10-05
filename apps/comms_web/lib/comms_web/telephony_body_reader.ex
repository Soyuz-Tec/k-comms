defmodule CommsWeb.TelephonyBodyReader do
  @moduledoc "Preserves the exact LiveKit webhook body for its signed SHA-256 claim."

  import Plug.Conn, only: [put_private: 3, read_body: 2]

  @maximum_body_bytes 262_144

  def read(conn, opts) do
    opts = bounded_options(conn, opts)

    case read_body(conn, opts) do
      {status, body, conn} when status in [:ok, :more] ->
        {status, body, preserve(conn, body)}

      result ->
        result
    end
  end

  defp preserve(%{method: "POST", request_path: "/api/v1/telephony/livekit/webhook"} = conn, body) do
    previous = conn.private[:telephony_webhook_body] || ""

    if byte_size(previous) + byte_size(body) > @maximum_body_bytes do
      raise Plug.Parsers.RequestTooLargeError
    end

    put_private(conn, :telephony_webhook_body, previous <> body)
  end

  defp preserve(
         %{method: "POST", request_path: "/api/v1/providers/livekit/egress/webhook"} = conn,
         body
       ) do
    previous = conn.private[:call_artifact_webhook_body] || ""

    if byte_size(previous) + byte_size(body) > @maximum_body_bytes do
      raise Plug.Parsers.RequestTooLargeError
    end

    put_private(conn, :call_artifact_webhook_body, previous <> body)
  end

  defp preserve(%{method: "POST", request_path: "/api/v1/telephony/pbx/webhook"} = conn, body) do
    previous = conn.private[:telephony_pbx_webhook_body] || ""

    if byte_size(previous) + byte_size(body) > @maximum_body_bytes,
      do: raise(Plug.Parsers.RequestTooLargeError)

    put_private(conn, :telephony_pbx_webhook_body, previous <> body)
  end

  defp preserve(conn, _body), do: conn

  defp bounded_options(
         %{method: "POST", request_path: "/api/v1/telephony/livekit/webhook"} = conn,
         opts
       ) do
    remaining = @maximum_body_bytes - byte_size(conn.private[:telephony_webhook_body] || "")
    probe_length = remaining + 1

    opts
    |> Keyword.update(:length, probe_length, &min(&1, probe_length))
    |> Keyword.update(:read_length, probe_length, &min(&1, probe_length))
  end

  defp bounded_options(
         %{method: "POST", request_path: "/api/v1/providers/livekit/egress/webhook"} = conn,
         opts
       ) do
    remaining = @maximum_body_bytes - byte_size(conn.private[:call_artifact_webhook_body] || "")
    probe_length = remaining + 1

    opts
    |> Keyword.update(:length, probe_length, &min(&1, probe_length))
    |> Keyword.update(:read_length, probe_length, &min(&1, probe_length))
  end

  defp bounded_options(
         %{method: "POST", request_path: "/api/v1/telephony/pbx/webhook"} = conn,
         opts
       ) do
    remaining = @maximum_body_bytes - byte_size(conn.private[:telephony_pbx_webhook_body] || "")
    probe_length = remaining + 1

    opts
    |> Keyword.update(:length, probe_length, &min(&1, probe_length))
    |> Keyword.update(:read_length, probe_length, &min(&1, probe_length))
  end

  defp bounded_options(_conn, opts), do: opts
end
