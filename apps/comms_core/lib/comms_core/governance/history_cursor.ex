defmodule CommsCore.Governance.HistoryCursor do
  @moduledoc false

  @domain "governance-deletion-history:v1:"
  @ttl_seconds 3_600
  @maximum_token_bytes 12_000
  @enforce_keys [:tenant_id, :request_id, :snapshot_id, :observed_at, :expires_at]
  defstruct [:tenant_id, :request_id, :snapshot_id, :observed_at, :expires_at, :after, :limit]

  def new(tenant_id, request_id, snapshot_id, observed_at) do
    %__MODULE__{
      tenant_id: tenant_id,
      request_id: request_id,
      snapshot_id: snapshot_id,
      observed_at: observed_at,
      expires_at: DateTime.to_unix(observed_at) + @ttl_seconds
    }
  end

  def seal(%__MODULE__{} = cursor, kind) when kind in [:snapshot, :cursor] do
    with {:ok, key} <- key() do
      payload = %{
        "v" => 1,
        "kind" => Atom.to_string(kind),
        "tenant" => cursor.tenant_id,
        "request" => cursor.request_id,
        "snapshot" => cursor.snapshot_id,
        "observed" => DateTime.to_iso8601(cursor.observed_at),
        "expires" => cursor.expires_at,
        "after" => encode_boundary(cursor.after),
        "limit" => cursor.limit
      }

      encoded = payload |> Jason.encode!() |> Base.url_encode64(padding: false)
      signature = :crypto.mac(:hmac, :sha256, key, @domain <> encoded)
      token = encoded <> "." <> Base.url_encode64(signature, padding: false)

      if byte_size(token) <= @maximum_token_bytes,
        do: {:ok, token},
        else: {:error, :history_unavailable}
    end
  end

  def open(token, kind, tenant_id, request_id)
      when is_binary(token) and
             byte_size(token) <= @maximum_token_bytes and kind in [:snapshot, :cursor] do
    with {:ok, key} <- key(),
         [encoded, signature] <- String.split(token, ".", parts: 2),
         {:ok, mac} <- Base.url_decode64(signature, padding: false),
         true <- byte_size(mac) == 32,
         expected = :crypto.mac(:hmac, :sha256, key, @domain <> encoded),
         true <- :crypto.hash_equals(mac, expected),
         {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, payload} <- Jason.decode(json),
         %{
           "v" => 1,
           "kind" => expected_kind,
           "tenant" => ^tenant_id,
           "request" => ^request_id,
           "snapshot" => snapshot_id,
           "observed" => observed,
           "expires" => expires,
           "after" => after_value,
           "limit" => limit
         } <- payload,
         true <- expected_kind == Atom.to_string(kind),
         {:ok, snapshot_id} <- Ecto.UUID.cast(snapshot_id),
         {:ok, after_value} <- decode_boundary(after_value),
         {:ok, observed_at, 0} <- DateTime.from_iso8601(observed),
         true <- is_integer(expires) and expires == DateTime.to_unix(observed_at) + @ttl_seconds,
         true <- DateTime.to_unix(DateTime.utc_now()) < expires,
         true <- valid_position?(kind, limit, after_value) do
      {:ok,
       %__MODULE__{
         tenant_id: tenant_id,
         request_id: request_id,
         snapshot_id: snapshot_id,
         observed_at: observed_at,
         expires_at: expires,
         after: after_value,
         limit: limit
       }}
    else
      {:error, :history_unavailable} = error -> error
      _ -> {:error, :invalid_history_cursor}
    end
  end

  def open(_token, _kind, _tenant_id, _request_id), do: {:error, :invalid_history_cursor}

  def configured?, do: key()

  defp key do
    case Application.get_env(:comms_core, :governance_history_cursor_key) do
      key when is_binary(key) and byte_size(key) >= 32 -> {:ok, key}
      _ -> {:error, :history_unavailable}
    end
  end

  defp encode_boundary(nil), do: nil
  defp encode_boundary({timestamp, id}), do: [DateTime.to_iso8601(timestamp), id]
  defp decode_boundary(nil), do: {:ok, nil}

  defp decode_boundary([timestamp, id]) when is_binary(timestamp) do
    with {:ok, time, 0} <- DateTime.from_iso8601(timestamp),
         {:ok, uuid} <- Ecto.UUID.cast(id),
         do: {:ok, {time, uuid}},
         else: (_ -> {:error, :invalid_history_cursor})
  end

  defp decode_boundary(_), do: {:error, :invalid_history_cursor}

  defp valid_position?(:snapshot, nil, nil), do: true

  defp valid_position?(:cursor, limit, {%DateTime{}, _id})
       when is_integer(limit) and limit in 1..50, do: true

  defp valid_position?(_, _, _), do: false
end
