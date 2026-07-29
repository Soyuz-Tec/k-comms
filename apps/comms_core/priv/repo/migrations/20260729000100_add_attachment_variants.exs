defmodule CommsCore.Repo.Migrations.AddAttachmentVariants do
  use Ecto.Migration

  def up do
    create table(:attachment_variants, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(
        :attachment_id,
        references(:attachments, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:kind, :text, null: false)
      add(:object_key, :text, null: false)
      add(:content_type, :text, null: false)
      add(:byte_size, :integer, null: false)
      add(:checksum_sha256, :text, null: false)
      add(:object_version_id, :text)
      add(:uploaded_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    # One variant per kind per attachment. A second row for the same kind would
    # orphan the first object, because only one key can be reached through the
    # attachment that owns it.
    create(
      unique_index(
        :attachment_variants,
        [:attachment_id, :kind],
        name: :attachment_variants_attachment_kind_unique
      )
    )

    create(unique_index(:attachment_variants, [:object_key]))

    # Cleanup enumerates an attachment's variants, so the lookup is by owner.
    create(
      index(
        :attachment_variants,
        [:tenant_id, :attachment_id],
        name: :attachment_variants_tenant_attachment_index
      )
    )

    create(
      constraint(
        :attachment_variants,
        :attachment_variants_kind_allowed,
        check: "kind IN ('thumbnail')"
      )
    )

    # Only non-executable raster types are storable. SVG is excluded because it
    # is scriptable, and a variant is the one attachment surface rendered inline
    # rather than downloaded.
    create(
      constraint(
        :attachment_variants,
        :attachment_variants_content_type_allowed,
        check: "content_type IN ('image/webp', 'image/jpeg', 'image/png')"
      )
    )

    create(
      constraint(
        :attachment_variants,
        :attachment_variants_byte_size_bounded,
        check: "byte_size > 0 AND byte_size <= 524288"
      )
    )

    create(
      constraint(
        :attachment_variants,
        :attachment_variants_checksum_format,
        check: "checksum_sha256 ~ '^[a-f0-9]{64}$'"
      )
    )

    # The version and upload time are written together at verification. A row
    # without a version is declared intent; with one, it is a reachable object.
    create(
      constraint(
        :attachment_variants,
        :attachment_variants_verification_consistent,
        check:
          "(object_version_id IS NULL AND uploaded_at IS NULL) OR " <>
            "(object_version_id IS NOT NULL AND uploaded_at IS NOT NULL)"
      )
    )

    # The tenant is carried on the row and pinned to the owning attachment's
    # tenant, so a variant can never be created against another tenant's
    # attachment even if the identifier is guessed.
    execute("""
    ALTER TABLE attachment_variants
      ADD CONSTRAINT attachment_variants_tenant_attachment_fk
        FOREIGN KEY (tenant_id, attachment_id) REFERENCES attachments (tenant_id, id)
    """)
  end

  def down do
    drop(table(:attachment_variants))
  end
end
