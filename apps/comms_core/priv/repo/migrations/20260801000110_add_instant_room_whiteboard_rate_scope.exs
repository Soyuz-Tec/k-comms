defmodule CommsCore.Repo.Migrations.AddInstantRoomWhiteboardRateScope do
  use Ecto.Migration

  def up do
    drop(
      constraint(
        :public_rate_limit_buckets,
        :public_rate_limit_buckets_scope_check
      )
    )

    create(
      constraint(
        :public_rate_limit_buckets,
        :public_rate_limit_buckets_scope_check,
        check:
          "scope IN ('instant_room_create', 'instant_room_join', " <>
            "'instant_room_conversion', 'instant_room_message', " <>
            "'instant_room_whiteboard')"
      )
    )
  end

  def down do
    drop(
      constraint(
        :public_rate_limit_buckets,
        :public_rate_limit_buckets_scope_check
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
  end
end
