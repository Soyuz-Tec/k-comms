defmodule CommsCore.Notifications.SchemaContainmentTest do
  use ExUnit.Case, async: true

  alias CommsCore.Notifications.{Attempt, Intent, Preference, PushSubscription}

  test "identity references remain scalar UUIDs instead of foreign schema associations" do
    assert_uuid_fields(Attempt, [:tenant_id])
    assert_uuid_fields(Intent, [:tenant_id, :user_id])
    assert_uuid_fields(Preference, [:tenant_id, :user_id])
    assert_uuid_fields(PushSubscription, [:tenant_id, :user_id, :device_id])

    for schema <- [Attempt, Intent, Preference, PushSubscription],
        association <- [:tenant, :user, :device] do
      refute association in schema.__schema__(:associations)
    end
  end

  test "owner-internal notification associations remain intact" do
    assert :intent in Attempt.__schema__(:associations)
    assert :push_subscription in Intent.__schema__(:associations)
  end

  defp assert_uuid_fields(schema, fields) do
    for field <- fields do
      assert schema.__schema__(:type, field) == Ecto.UUID
    end
  end
end
