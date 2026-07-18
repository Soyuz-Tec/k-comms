defmodule CommsCore.TrustGovernance.SchemaContainmentTest do
  use ExUnit.Case, async: true

  alias CommsCore.Governance.{DeletionRequest, LegalHold, RetentionPolicy}
  alias CommsCore.Moderation.{ModerationAction, ModerationCase}

  test "foreign identity and content references remain scalar UUIDs" do
    assert_uuid_fields(DeletionRequest, [
      :tenant_id,
      :requested_by_user_id,
      :subject_user_id,
      :conversation_id,
      :message_id
    ])

    assert_uuid_fields(LegalHold, [
      :tenant_id,
      :created_by_user_id,
      :subject_user_id,
      :conversation_id
    ])

    assert_uuid_fields(RetentionPolicy, [:tenant_id, :conversation_id])

    assert_uuid_fields(ModerationCase, [
      :tenant_id,
      :reporter_user_id,
      :subject_user_id,
      :conversation_id,
      :message_id,
      :assigned_to_user_id
    ])

    assert_uuid_fields(ModerationAction, [:tenant_id, :actor_user_id])
  end

  test "foreign associations are absent and the owner-internal association remains" do
    assert DeletionRequest.__schema__(:associations) == []
    assert LegalHold.__schema__(:associations) == []
    assert RetentionPolicy.__schema__(:associations) == []
    assert ModerationCase.__schema__(:associations) == []
    assert ModerationAction.__schema__(:associations) == [:moderation_case]
  end

  defp assert_uuid_fields(schema, fields) do
    for field <- fields do
      assert schema.__schema__(:type, field) == Ecto.UUID
    end
  end
end
