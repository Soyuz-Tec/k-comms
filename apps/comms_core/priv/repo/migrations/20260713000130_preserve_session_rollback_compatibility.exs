defmodule CommsCore.Repo.Migrations.PreserveSessionRollbackCompatibility do
  use Ecto.Migration

  @set_compatibility_default """
  ALTER TABLE sessions
  ALTER COLUMN absolute_expires_at
  SET DEFAULT (
    (CURRENT_TIMESTAMP AT TIME ZONE 'UTC') + INTERVAL '30 days'
  )
  """

  def up do
    # Reconcile environments that applied 20260713000120 before its
    # one-release compatibility default was added.
    execute(@set_compatibility_default)
  end

  def down do
    # The preceding migration now owns this compatibility invariant. Retain it
    # until that migration removes the column so a partial migration rollback
    # cannot strand the previous application release.
    execute(@set_compatibility_default)
  end
end
