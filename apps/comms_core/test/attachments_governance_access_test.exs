defmodule CommsCore.Attachments.GovernanceAccessTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Attachments
  alias CommsCore.Attachments.{Attachment, AttachmentDeletionObject}
  alias CommsCore.Messaging
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  test "erasure objects are an ordered tenant-scoped union of message and user ownership" do
    account = Fixtures.account_fixture()
    other_account = Fixtures.account_fixture()
    other_user = Fixtures.user_fixture(account).user
    selected_message = message_fixture(account, "selected")
    unrelated_message = message_fixture(account, "unrelated")
    foreign_message = message_fixture(other_account, "foreign")

    selected_by_message =
      attachment_fixture(account, other_user.id, selected_message.id, :pending, "message")

    selected_by_user =
      attachment_fixture(account, account.user.id, unrelated_message.id, :uploaded, "user")

    selected_by_both =
      attachment_fixture(account, account.user.id, selected_message.id, :quarantined, "both")

    excluded =
      attachment_fixture(account, other_user.id, unrelated_message.id, :scan_failed, "excluded")

    deleted =
      attachment_fixture(account, account.user.id, selected_message.id, :deleted, "deleted")

    foreign =
      attachment_fixture(
        other_account,
        other_account.user.id,
        foreign_message.id,
        :pending,
        "foreign"
      )

    objects =
      Attachments.erasure_objects(
        account.tenant.id,
        [selected_message.id, selected_message.id, foreign_message.id],
        account.user.id
      )

    expected_ids =
      [selected_by_message.id, selected_by_user.id, selected_by_both.id]
      |> Enum.sort()

    assert Enum.map(objects, & &1.id) == expected_ids
    assert Enum.all?(objects, &match?(%AttachmentDeletionObject{}, &1))
    assert Enum.all?(objects, &(&1.tenant_id == account.tenant.id))
    assert Enum.all?(objects, &is_binary(&1.object_key))
    assert Enum.all?(objects, &is_binary(&1.object_version_id))

    refute Enum.any?(objects, &(&1.id in [excluded.id, deleted.id, foreign.id]))
    refute Enum.any?(objects, &Map.has_key?(&1, :owner_user_id))
    refute Enum.any?(objects, &Map.has_key?(&1, :message_id))

    message_objects =
      Attachments.erasure_objects(account.tenant.id, [selected_message.id], nil)

    assert Enum.map(message_objects, & &1.id) ==
             Enum.sort([selected_by_message.id, selected_by_both.id])

    user_objects = Attachments.erasure_objects(account.tenant.id, [], account.user.id)

    assert Enum.map(user_objects, & &1.id) ==
             Enum.sort([selected_by_user.id, selected_by_both.id])

    assert [] =
             Attachments.erasure_objects(
               account.tenant.id,
               [foreign_message.id],
               nil
             )
  end

  test "erasure objects fail closed for empty or malformed scopes" do
    account = Fixtures.account_fixture()
    message = message_fixture(account, "invalid-scope")

    _attachment =
      attachment_fixture(account, account.user.id, message.id, :pending, "invalid-scope")

    assert [] = Attachments.erasure_objects(account.tenant.id, [], nil)
    assert [] = Attachments.erasure_objects("not-a-tenant", [message.id], nil)
    assert [] = Attachments.erasure_objects(account.tenant.id, ["not-a-message"], nil)
    assert [] = Attachments.erasure_objects(account.tenant.id, [message.id], "not-a-user")
    assert [] = Attachments.erasure_objects(account.tenant.id, :not_a_list, nil)
  end

  defp message_fixture(account, suffix) do
    assert {:ok, message} =
             Messaging.accept_message(
               %{
                 tenant_id: account.tenant.id,
                 conversation_id: account.conversation.id,
                 sender_user_id: account.user.id,
                 sender_device_id: account.device.id,
                 client_message_id:
                   "attachment-governance-#{suffix}-#{System.unique_integer([:positive])}",
                 body: "governed attachment"
               },
               Fixtures.subject(account)
             )

    message
  end

  defp attachment_fixture(account, owner_user_id, message_id, status, suffix) do
    unique = System.unique_integer([:positive, :monotonic])

    %Attachment{}
    |> Attachment.changeset(%{
      tenant_id: account.tenant.id,
      owner_user_id: owner_user_id,
      message_id: message_id,
      object_key: "#{account.tenant.id}/governance/#{suffix}-#{unique}",
      object_version_id: "version-#{suffix}-#{unique}",
      file_name: "#{suffix}.txt",
      content_type: "text/plain",
      byte_size: 10,
      status: status,
      scan_status: :pending
    })
    |> Repo.insert!()
  end
end
