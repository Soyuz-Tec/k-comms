defmodule CommsCore.ModerationBoundaryTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Messaging, Moderation}
  alias CommsCore.Moderation.{ActionView, CaseView}
  alias CommsTestSupport.Fixtures

  test "message reports and assignments cross owner boundaries through public contracts" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    moderator = Fixtures.user_fixture(account, %{role: :moderator})
    ineligible_member = Fixtures.user_fixture(account)
    foreign_account = Fixtures.account_fixture()

    assert {:ok, message} =
             Messaging.accept_message(
               %{
                 tenant_id: account.tenant.id,
                 conversation_id: account.conversation.id,
                 sender_user_id: account.user.id,
                 sender_device_id: account.device.id,
                 client_message_id: "moderation-boundary-message",
                 body: "Evidence for the moderation boundary"
               },
               subject
             )

    assert {:ok, %{case: %CaseView{} = moderation_case, replayed: false}} =
             Moderation.create_case_view(
               %{
                 message_id: message.id,
                 category: "abuse",
                 summary: "Review the reported message"
               },
               subject
             )

    assert moderation_case.message_id == message.id
    assert moderation_case.conversation_id == account.conversation.id
    refute Map.has_key?(moderation_case, :__meta__)

    stepped_up_subject = Fixtures.step_up(account, subject)

    assert {:error, :invalid_assignee} =
             Moderation.add_action_view(
               moderation_case.id,
               %{
                 version: moderation_case.version,
                 action_type: "assign",
                 assigned_to_user_id: ineligible_member.user.id
               },
               stepped_up_subject
             )

    assert {:error, :invalid_assignee} =
             Moderation.add_action_view(
               moderation_case.id,
               %{
                 version: moderation_case.version,
                 action_type: "assign",
                 assigned_to_user_id: foreign_account.user.id
               },
               stepped_up_subject
             )

    assert {:ok, %{case: %CaseView{} = assigned, action: %ActionView{} = action}} =
             Moderation.add_action_view(
               moderation_case.id,
               %{
                 version: moderation_case.version,
                 action_type: "assign",
                 assigned_to_user_id: moderator.user.id
               },
               stepped_up_subject
             )

    assert assigned.assigned_to_user_id == moderator.user.id
    assert assigned.status == :in_review
    assert action.action_type == :assign
    refute Map.has_key?(assigned, :__meta__)
    refute Map.has_key?(action, :__meta__)

    assert {:ok, %{case: %CaseView{} = fetched, actions: [%ActionView{} = fetched_action]}} =
             Moderation.get_case_view(moderation_case.id, stepped_up_subject)

    assert fetched.id == moderation_case.id
    assert fetched.assigned_to_user_id == moderator.user.id
    assert fetched_action.id == action.id
    refute Map.has_key?(fetched, :__meta__)
    refute Map.has_key?(fetched_action, :__meta__)
  end

  test "foreign-tenant user, conversation, and message targets retain the public error" do
    account = Fixtures.account_fixture()
    foreign_account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    foreign_subject = Fixtures.subject(foreign_account)

    assert {:ok, foreign_message} =
             Messaging.accept_message(
               %{
                 tenant_id: foreign_account.tenant.id,
                 conversation_id: foreign_account.conversation.id,
                 sender_user_id: foreign_account.user.id,
                 sender_device_id: foreign_account.device.id,
                 client_message_id: "foreign-moderation-boundary-message",
                 body: "Foreign-tenant evidence"
               },
               foreign_subject
             )

    base_attrs = %{category: "abuse", summary: "Reject a foreign-tenant target"}

    for target_attrs <- [
          %{subject_user_id: foreign_account.user.id},
          %{conversation_id: foreign_account.conversation.id},
          %{message_id: foreign_message.id}
        ] do
      assert {:error, :invalid_moderation_target} =
               target_attrs
               |> Map.merge(base_attrs)
               |> Moderation.create_case_view(subject)
    end
  end

  test "moderation facade contains no foreign persistence-schema reach-through" do
    source =
      __DIR__
      |> Path.join("../lib/comms_core/moderation.ex")
      |> Path.expand()
      |> File.read!()

    refute source =~ "CommsCore.Accounts.User"
    refute source =~ "CommsCore.Conversations.Conversation"
    refute source =~ "CommsCore.Messaging.Message"
    refute source =~ "preload: [:reporter_user, :subject_user, :assigned_to_user]"
  end
end
