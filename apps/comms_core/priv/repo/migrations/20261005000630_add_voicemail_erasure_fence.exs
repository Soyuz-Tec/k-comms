defmodule CommsCore.Repo.Migrations.AddVoicemailErasureFence do
  use Ecto.Migration

  def up do
    alter table(:telephony_voicemails) do
      add(:protected_user_ids, {:array, :binary_id}, null: false, default: [])
      add(:erasure_requested_at, :utc_datetime_usec)
      add(:erasure_verified_at, :utc_datetime_usec)
    end

    execute("""
    UPDATE telephony_voicemails AS v SET protected_user_ids =
      ARRAY(SELECT DISTINCT user_id FROM unnest(ARRAY[v.user_id, c.user_id]) AS user_id WHERE user_id IS NOT NULL)
    FROM telephony_calls AS c WHERE c.id = v.call_id AND c.tenant_id = v.tenant_id
    """)

    create(
      index(:telephony_voicemails, [:tenant_id, :erasure_requested_at],
        where: "erasure_requested_at IS NOT NULL"
      )
    )

    create(
      constraint(:telephony_voicemails, :voicemail_erasure_verified_state,
        check:
          "erasure_verified_at IS NULL OR (status = 'deleted' AND deleted_at IS NOT NULL AND provider_deleted_at IS NOT NULL)"
      )
    )
  end

  def down do
    drop(constraint(:telephony_voicemails, :voicemail_erasure_verified_state))

    drop(
      index(:telephony_voicemails, [:tenant_id, :erasure_requested_at],
        where: "erasure_requested_at IS NOT NULL"
      )
    )

    alter table(:telephony_voicemails) do
      remove(:protected_user_ids)
      remove(:erasure_requested_at)
      remove(:erasure_verified_at)
    end
  end
end
