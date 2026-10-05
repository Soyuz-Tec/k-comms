defmodule CommsCore.Accounts.ProfileValidation do
  @moduledoc false

  # Schema validation must not depend on availability's authorization and
  # persistence workflow, which itself consumes the canonical User schema.
  def valid_timezone?(zone) when is_binary(zone) and byte_size(zone) <= 100 do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    match?({:ok, _}, DateTime.shift_zone(timestamp, zone, Tzdata.TimeZoneDatabase))
  end

  def valid_timezone?(_), do: false

  def valid_avatar?(nil), do: true
  def valid_avatar?(""), do: true

  def valid_avatar?("data:image/png;base64," <> encoded) when byte_size(encoded) <= 131_072 do
    case Base.decode64(encoded) do
      {:ok, <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", width::32, height::32, _::binary>>} ->
        width in 1..512 and height in 1..512

      _ ->
        false
    end
  end

  def valid_avatar?(_), do: false
end
