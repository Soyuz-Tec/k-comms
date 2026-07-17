defmodule CommsCore.Repo.Migrations.AddVideoCalls do
  use Ecto.Migration

  def up do
    alter table(:tenant_settings) do
      add(:allow_video_calls, :boolean, null: false, default: true)
    end

    alter table(:audio_calls) do
      add(:media_kind, :string, null: false, default: "audio")
    end

    execute("UPDATE audio_calls SET media_kind = 'audio' WHERE media_kind IS NULL")

    create(
      constraint(:audio_calls, :audio_calls_valid_media_kind,
        check: "media_kind IN ('audio', 'video')"
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM audio_calls WHERE media_kind = 'video') THEN
        RAISE EXCEPTION
          'cannot roll back video calls migration while video call evidence exists';
      END IF;

      IF EXISTS (SELECT 1 FROM tenant_settings WHERE allow_video_calls = false) THEN
        RAISE EXCEPTION
          'cannot roll back video calls migration while tenant video settings evidence exists';
      END IF;
    END
    $$
    """)

    drop(constraint(:audio_calls, :audio_calls_valid_media_kind))

    alter table(:audio_calls) do
      remove(:media_kind)
    end

    alter table(:tenant_settings) do
      remove(:allow_video_calls)
    end
  end
end
