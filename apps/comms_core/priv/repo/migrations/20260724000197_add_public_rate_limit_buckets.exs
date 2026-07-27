defmodule CommsCore.Repo.Migrations.AddPublicRateLimitBuckets do
  use Ecto.Migration

  def change do
    create table(:public_rate_limit_buckets, primary_key: false) do
      add(:scope, :string, null: false)
      add(:key_digest, :binary, null: false)
      add(:window_seconds, :bigint, null: false)
      add(:window_started_at, :utc_datetime_usec, null: false)
      add(:request_count, :bigint, null: false, default: 1)
      add(:expires_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(
        :public_rate_limit_buckets,
        [:scope, :key_digest, :window_seconds, :window_started_at],
        name: :public_rate_limit_buckets_scope_key_window_unique
      )
    )

    create(
      index(
        :public_rate_limit_buckets,
        [:expires_at],
        name: :public_rate_limit_buckets_expiry_index
      )
    )

    create(
      constraint(
        :public_rate_limit_buckets,
        :public_rate_limit_buckets_scope_check,
        check:
          "scope IN ('instant_room_create', 'instant_room_join', " <>
            "'instant_room_conversion', 'instant_room_message')"
      )
    )

    create(
      constraint(
        :public_rate_limit_buckets,
        :public_rate_limit_buckets_key_digest_check,
        check: "octet_length(key_digest) = 32"
      )
    )

    create(
      constraint(
        :public_rate_limit_buckets,
        :public_rate_limit_buckets_window_seconds_check,
        check: "window_seconds > 0"
      )
    )

    create(
      constraint(
        :public_rate_limit_buckets,
        :public_rate_limit_buckets_request_count_check,
        check: "request_count > 0"
      )
    )

    create(
      constraint(
        :public_rate_limit_buckets,
        :public_rate_limit_buckets_expiry_check,
        check: "expires_at > window_started_at"
      )
    )
  end
end
