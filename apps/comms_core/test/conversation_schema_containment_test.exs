defmodule CommsCore.Conversations.SchemaContainmentTest do
  use ExUnit.Case, async: true

  alias CommsCore.Conversations.{Conversation, Membership}

  test "identity references remain scalar UUIDs instead of foreign schema associations" do
    assert Conversation.__schema__(:type, :tenant_id) == Ecto.UUID
    assert Conversation.__schema__(:type, :created_by_user_id) == Ecto.UUID
    assert Membership.__schema__(:type, :tenant_id) == Ecto.UUID
    assert Membership.__schema__(:type, :user_id) == Ecto.UUID

    refute :tenant in Conversation.__schema__(:associations)
    refute :created_by_user in Conversation.__schema__(:associations)
    refute :tenant in Membership.__schema__(:associations)
    refute :user in Membership.__schema__(:associations)
  end

  test "the owner-internal conversation association remains intact" do
    assert :conversation in Membership.__schema__(:associations)
  end
end
