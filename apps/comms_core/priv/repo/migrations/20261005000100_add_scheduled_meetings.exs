defmodule CommsCore.Repo.Migrations.AddScheduledMeetings do
  use Ecto.Migration

  def change do
    create table(:meetings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, :binary_id, null: false
      add :conversation_id, :binary_id, null: false
      add :host_user_id, :binary_id, null: false
      add :title, :string, size: 200, null: false
      add :timezone, :string, size: 100, null: false
      add :local_start, :naive_datetime, null: false
      add :duration_minutes, :integer, null: false
      add :recurrence, :map, null: false
      add :reminder_minutes, :integer, null: false
      add :host_policy, :map, null: false
      add :status, :string, null: false, default: "scheduled"
      add :version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end
    create index(:meetings, [:tenant_id, :conversation_id])
    create unique_index(:meetings, [:tenant_id, :id])
    create constraint(:meetings, :meetings_bounded_duration,
      check: "duration_minutes BETWEEN 5 AND 480 AND reminder_minutes BETWEEN 0 AND 10080 AND version > 0")
    create constraint(:meetings, :meetings_valid_status, check: "status IN ('scheduled', 'cancelled')")

    create table(:meeting_occurrences, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, :binary_id, null: false
      add :meeting_id, references(:meetings, type: :binary_id, on_delete: :restrict,
        with: [tenant_id: :tenant_id]), null: false
      add :conversation_id, :binary_id, null: false
      add :call_id, references(:audio_calls, type: :binary_id, on_delete: :restrict,
        with: [tenant_id: :tenant_id])
      add :sequence, :integer, null: false
      add :meeting_version, :integer, null: false
      add :starts_at, :utc_datetime_usec, null: false
      add :ends_at, :utc_datetime_usec, null: false
      add :reminder_at, :utc_datetime_usec, null: false
      add :reminder_sent_at, :utc_datetime_usec
      add :status, :string, null: false, default: "scheduled"
      timestamps(type: :utc_datetime_usec)
    end
    create unique_index(:meeting_occurrences, [:meeting_id, :meeting_version, :sequence])
    create unique_index(:meeting_occurrences, [:call_id], where: "call_id IS NOT NULL")
    create index(:meeting_occurrences, [:tenant_id, :starts_at, :id])
    create constraint(:meeting_occurrences, :meeting_occurrences_bounded_duration,
      check: "ends_at > starts_at AND ends_at <= starts_at + interval '8 hours'")
    create constraint(:meeting_occurrences, :meeting_occurrences_valid_status,
      check: "status IN ('scheduled', 'cancelled') AND sequence BETWEEN 1 AND 52 AND meeting_version > 0")
  end
end
