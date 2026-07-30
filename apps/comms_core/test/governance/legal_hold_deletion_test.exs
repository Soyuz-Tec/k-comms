defmodule CommsCore.Governance.LegalHoldDeletionTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Governance, Messaging, RuntimePorts}
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :governance

  test "a user legal hold blocks deletion of that user's message" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, message} =
             Messaging.accept_message(
               %{
                 tenant_id: account.tenant.id,
                 conversation_id: account.conversation.id,
                 sender_user_id: account.user.id,
                 sender_device_id: account.device.id,
                 client_message_id: "held-message-#{System.unique_integer([:positive])}",
                 body: "preserved evidence"
               },
               subject
             )

    assert {:ok, _hold} =
             Governance.create_legal_hold(
               %{
                 name: "User evidence hold",
                 reason: "Preserve all content authored by this user",
                 scope_type: "user",
                 subject_user_id: account.user.id
               },
               subject
             )

    assert {:ok, request_result} =
             Governance.create_deletion_request(
               %{
                 target_type: "message",
                 message_id: message.id,
                 reason: "Requested message deletion"
               },
               subject
             )

    assert {:ok, _approved} =
             Governance.transition_deletion_request(
               request_result.request.id,
               %{
                 version: request_result.request.lock_version,
                 status: "approved",
                 transition_reason: "Request identity verified"
               },
               subject
             )

    assert {:error, :legal_hold_active} =
             Governance.claim_deletion_request(
               request_result.request.id,
               :"Elixir.CommsWorkers.DeletionWorker"
             )
  end

  test "direct message deletion honors tenant, user, and conversation legal holds" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, message} =
             Messaging.accept_message(
               %{
                 tenant_id: account.tenant.id,
                 conversation_id: account.conversation.id,
                 sender_user_id: account.user.id,
                 sender_device_id: account.device.id,
                 client_message_id: "direct-held-message",
                 body: "preserve direct deletion evidence"
               },
               subject
             )

    hold_attrs = [
      %{scope_type: "tenant"},
      %{scope_type: "user", subject_user_id: account.user.id},
      %{scope_type: "conversation", conversation_id: account.conversation.id}
    ]

    Enum.with_index(hold_attrs, 1)
    |> Enum.each(fn {scope_attrs, index} ->
      assert {:ok, %{hold: hold}} =
               Governance.create_legal_hold(
                 Map.merge(scope_attrs, %{
                   name: "Direct deletion hold #{index}",
                   reason: "Preserve content while direct deletion is evaluated"
                 }),
                 subject
               )

      assert {:error, :legal_hold_active} = Governance.delete_message(message.id, subject)

      assert {:ok, released} =
               Governance.release_legal_hold(
                 hold.id,
                 %{
                   version: hold.lock_version,
                   release_reason: "Direct deletion regression check completed"
                 },
                 subject
               )

      assert released.status == :released
    end)

    assert {:ok, deleted} = Governance.delete_message(message.id, subject)
    assert deleted.status == :deleted
  end

  test "a conversation hold blocks deletion even when the conversation has no messages" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, %{hold: _hold}} =
             Governance.create_legal_hold(
               %{
                 name: "Empty conversation hold",
                 reason: "Preserve the validated conversation target itself",
                 scope_type: "conversation",
                 conversation_id: account.conversation.id
               },
               subject
             )

    assert {:ok, %{request: request}} =
             Governance.create_deletion_request(
               %{
                 target_type: "conversation",
                 conversation_id: account.conversation.id,
                 reason: "Exercise the empty-conversation governance boundary"
               },
               subject
             )

    assert {:ok, approved} =
             Governance.transition_deletion_request(
               request.id,
               %{
                 version: request.lock_version,
                 status: "approved",
                 transition_reason: "Approve the bounded deletion request"
               },
               subject
             )

    assert {:error, :legal_hold_active} =
             Governance.claim_deletion_request(
               approved.id,
               RuntimePorts.job_worker!(:deletion)
             )
  end
end
