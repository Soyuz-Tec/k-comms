defmodule CommsCore.PlatformRateLimits.Bucket do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  schema "public_rate_limit_buckets" do
    field(:scope, :string)
    field(:key_digest, :binary)
    field(:window_seconds, :integer)
    field(:window_started_at, :utc_datetime_usec)
    field(:request_count, :integer)
    field(:expires_at, :utc_datetime_usec)
  end
end
