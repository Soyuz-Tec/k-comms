defmodule CommsCore.Repo.Migrations.AllowOrphanedPushIntentVersions do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE notification_intents
    DROP CONSTRAINT notification_intents_push_subscription_shape,
    ADD CONSTRAINT notification_intents_push_subscription_shape
    CHECK (
      (
        push_subscription_id IS NULL AND
        (push_subscription_version IS NULL OR push_subscription_version > 0)
      ) OR
      (push_subscription_id IS NOT NULL AND push_subscription_version > 0)
    )
    """)
  end

  def down do
    execute("""
    UPDATE notification_intents
    SET push_subscription_version = NULL
    WHERE push_subscription_id IS NULL
    """)

    execute("""
    ALTER TABLE notification_intents
    DROP CONSTRAINT notification_intents_push_subscription_shape,
    ADD CONSTRAINT notification_intents_push_subscription_shape
    CHECK (
      (push_subscription_id IS NULL AND push_subscription_version IS NULL) OR
      (push_subscription_id IS NOT NULL AND push_subscription_version > 0)
    )
    """)
  end
end
