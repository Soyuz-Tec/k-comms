defmodule CommsCore.Repo.Migrations.AddAudioCallEndingState do
  use Ecto.Migration

  def up do
    drop(constraint(:audio_calls, :audio_calls_valid_status))
    drop(constraint(:audio_calls, :audio_calls_end_state_consistent))

    drop(
      index(:audio_calls, [:tenant_id, :conversation_id],
        name: :audio_calls_one_active_per_conversation
      )
    )

    create(
      unique_index(:audio_calls, [:tenant_id, :conversation_id],
        where: "status IN ('active', 'ending')",
        name: :audio_calls_one_active_per_conversation
      )
    )

    create(
      constraint(:audio_calls, :audio_calls_valid_status,
        check: "status IN ('active', 'ending', 'ended')"
      )
    )

    create(
      constraint(:audio_calls, :audio_calls_end_state_consistent,
        check:
          "(status IN ('active', 'ending') AND ended_at IS NULL AND ended_by_user_id IS NULL AND end_reason IS NULL) OR " <>
            "(status = 'ended' AND ended_at IS NOT NULL AND end_reason IS NOT NULL)"
      )
    )
  end

  def down do
    execute("UPDATE audio_calls SET status = 'active' WHERE status = 'ending'")

    drop(constraint(:audio_calls, :audio_calls_valid_status))
    drop(constraint(:audio_calls, :audio_calls_end_state_consistent))

    drop(
      index(:audio_calls, [:tenant_id, :conversation_id],
        name: :audio_calls_one_active_per_conversation
      )
    )

    create(
      unique_index(:audio_calls, [:tenant_id, :conversation_id],
        where: "status = 'active'",
        name: :audio_calls_one_active_per_conversation
      )
    )

    create(
      constraint(:audio_calls, :audio_calls_valid_status, check: "status IN ('active', 'ended')")
    )

    create(
      constraint(:audio_calls, :audio_calls_end_state_consistent,
        check:
          "(status = 'active' AND ended_at IS NULL AND ended_by_user_id IS NULL AND end_reason IS NULL) OR " <>
            "(status = 'ended' AND ended_at IS NOT NULL AND end_reason IS NOT NULL)"
      )
    )
  end
end
