defmodule CommsCore.ConversationContent.SchemaContainmentTest do
  use ExUnit.Case, async: true

  alias CommsCore.Attachments.{Attachment, ScanAttempt}
  alias CommsCore.Messaging.{Message, MessageMention, MessageRevision, Reaction}

  test "foreign identity, tenant, and conversation references remain scalar UUIDs" do
    assert_uuid_fields(Message, [
      :tenant_id,
      :conversation_id,
      :sender_user_id,
      :sender_device_id
    ])

    assert_uuid_fields(MessageMention, [:tenant_id, :user_id])
    assert_uuid_fields(MessageRevision, [:tenant_id, :editor_user_id])
    assert_uuid_fields(Reaction, [:tenant_id, :user_id])
    assert_uuid_fields(Attachment, [:tenant_id, :owner_user_id])
    assert_uuid_fields(ScanAttempt, [:tenant_id])
  end

  test "foreign associations are absent and owner-internal associations remain intact" do
    for {schema, associations} <- [
          {Message, [:tenant, :conversation, :sender_user, :sender_device]},
          {MessageMention, [:tenant, :user]},
          {MessageRevision, [:tenant, :editor_user]},
          {Reaction, [:tenant, :user]},
          {Attachment, [:tenant, :owner_user]},
          {ScanAttempt, [:tenant]}
        ],
        association <- associations do
      refute association in schema.__schema__(:associations)
    end

    assert :reply_to_message in Message.__schema__(:associations)
    assert :thread_root_message in Message.__schema__(:associations)
    assert :attachments in Message.__schema__(:associations)
    assert :reactions in Message.__schema__(:associations)
    assert :mentions in Message.__schema__(:associations)
    assert :message in MessageRevision.__schema__(:associations)
    assert :scan_attempt_records in Attachment.__schema__(:associations)
  end

  defp assert_uuid_fields(schema, fields) do
    for field <- fields do
      assert schema.__schema__(:type, field) == Ecto.UUID
    end
  end
end
