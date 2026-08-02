defmodule CommsCore.Repo.Migrations.AddCallCollaboration do
  use Ecto.Migration

  def up do
    alter table(:audio_call_participants) do
      add_if_not_exists(:hand_raised_at, :utc_datetime_usec)
    end

    create_if_not_exists(
      index(:audio_call_participants, [:audio_call_id, :hand_raised_at],
        where: "status = 'admitted' AND hand_raised_at IS NOT NULL",
        name: :audio_call_participants_raised_hands_index
      )
    )
  end

  def down do
    drop_if_exists(
      index(:audio_call_participants, [:audio_call_id, :hand_raised_at],
        name: :audio_call_participants_raised_hands_index
      )
    )

    alter table(:audio_call_participants) do
      remove_if_exists(:hand_raised_at, :utc_datetime_usec)
    end
  end
end
