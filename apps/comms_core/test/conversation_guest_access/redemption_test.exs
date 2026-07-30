defmodule CommsCore.Conversations.GuestAccess.RedemptionTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query

  alias CommsCore.{Accounts, Conversations, Messaging, Repo}
  alias CommsCore.Conversations.{GuestAdmission, GuestLink}
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :conversation
  @moduletag :guest

  test "expired links are indistinguishable from malformed links" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok,
            %{
              guest_link: link,
              token: token,
              conversion_verification_code: nil
            }} =
             Conversations.create_guest_link_view(
               account.conversation.id,
               %{expires_in_seconds: 900},
               subject
             )

    inserted_at = DateTime.utc_now() |> DateTime.add(-3_600, :second)
    expired_at = DateTime.utc_now() |> DateTime.add(-1, :second)

    from(record in GuestLink, where: record.id == ^link.id)
    |> Repo.update_all(set: [inserted_at: inserted_at, expires_at: expired_at])

    assert {:error, :guest_link_unavailable} =
             Conversations.preview_guest_link(token)

    assert {:error, :guest_link_unavailable} =
             Conversations.redeem_guest_link(token, guest_attrs("Expired Guest"))

    assert {:error, :guest_link_unavailable} =
             Conversations.preview_guest_link("not-a-token")
  end

  test "database ownership rejects a guest admission linked to another conversation" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, other_conversation} =
             Conversations.create(
               %{kind: :group, title: "Other guest scope"},
               subject
             )

    assert {:ok, %{token: token}} =
             Conversations.create_guest_link_view(
               account.conversation.id,
               %{expires_in_seconds: 3_600, max_uses: 1},
               subject
             )

    assert {:ok, redemption} =
             Conversations.redeem_guest_link(token, guest_attrs("Scoped Guest"))

    admission = Repo.get!(GuestAdmission, redemption.admission.id)

    assert_raise Ecto.ConstraintError,
                 ~r/conversation_guest_admissions_tenant_link_fk/,
                 fn ->
                   Repo.transaction(fn ->
                     admission
                     |> Ecto.Changeset.change(%{conversation_id: other_conversation.id})
                     |> Repo.update!()
                   end)
                 end
  end

  test "guest history starts at admission and omits earlier messages" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, before_admission} =
             Messaging.accept_message(
               owner_message_attrs(account, "guest-history-before", "Before admission"),
               subject
             )

    assert {:ok, %{token: token}} =
             Conversations.create_guest_link_view(
               account.conversation.id,
               %{expires_in_seconds: 3_600},
               subject
             )

    assert {:ok, redemption} =
             Conversations.redeem_guest_link(token, guest_attrs("History Guest"))

    assert redemption.admission.history_from_sequence ==
             before_admission.conversation_sequence + 1

    assert {:ok, after_admission} =
             Messaging.accept_message(
               owner_message_attrs(account, "guest-history-after", "After admission"),
               subject
             )

    guest_subject = guest_subject(redemption)

    assert {:ok, history} =
             Messaging.list_history(account.conversation.id, guest_subject)

    assert Enum.map(history, & &1.id) == [after_admission.id]
    refute Enum.any?(history, &(&1.id == before_admission.id))

    assert {:error, :forbidden} =
             Messaging.list_history(
               account.conversation.id,
               Map.delete(guest_subject, :guest_history_from_sequence)
             )
  end

  defp guest_attrs(display_name) do
    %{
      display_name: display_name,
      device: %{name: "Guest browser", platform: "test"},
      request_id: "guest-access-test"
    }
  end

  defp guest_subject(redemption) do
    assert {:ok, context} =
             Accounts.guest_access_context(
               redemption.authentication.session_id,
               "guest-access-test"
             )

    Map.merge(context.subject, %{
      guest_admission_id: redemption.admission.id,
      guest_conversation_id: redemption.conversation.id,
      guest_history_from_sequence: redemption.admission.history_from_sequence
    })
  end

  defp owner_message_attrs(account, client_message_id, body) do
    %{
      tenant_id: account.tenant.id,
      conversation_id: account.conversation.id,
      sender_user_id: account.user.id,
      sender_device_id: account.device.id,
      client_message_id: client_message_id,
      body: body
    }
  end
end
