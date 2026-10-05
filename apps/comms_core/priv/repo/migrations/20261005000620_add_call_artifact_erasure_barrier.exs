defmodule CommsCore.Repo.Migrations.AddCallArtifactErasureBarrier do
  use Ecto.Migration

  def change do
    alter table(:call_artifacts) do
      add(:erasure_requested_at, :utc_datetime_usec)
      add(:requested_by_device_id, :uuid)
      add(:requested_by_session_id, :uuid)
    end

    create(
      index(:call_artifacts, [:erasure_requested_at],
        where: "status != 'deleted' AND erasure_requested_at IS NOT NULL"
      )
    )
  end
end
