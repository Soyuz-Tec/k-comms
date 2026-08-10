defmodule CommsCore.Repo.Migrations.AddDirectAudioRateScopes do
  use Ecto.Migration

  @constraint :public_rate_limit_buckets_scope_check

  def up do
    drop(constraint(:public_rate_limit_buckets, @constraint))

    create(
      constraint(
        :public_rate_limit_buckets,
        @constraint,
        check:
          "scope IN ('instant_room_create', 'instant_room_join', " <>
            "'instant_room_conversion', 'instant_room_message', " <>
            "'instant_room_whiteboard', 'direct_audio_join', " <>
            "'direct_audio_signal')"
      )
    )
  end

  def down do
    execute("""
    DELETE FROM public_rate_limit_buckets
    WHERE scope IN ('direct_audio_join', 'direct_audio_signal')
    """)

    drop(constraint(:public_rate_limit_buckets, @constraint))

    create(
      constraint(
        :public_rate_limit_buckets,
        @constraint,
        check:
          "scope IN ('instant_room_create', 'instant_room_join', " <>
            "'instant_room_conversion', 'instant_room_message', " <>
            "'instant_room_whiteboard')"
      )
    )
  end
end
