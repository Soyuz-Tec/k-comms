defmodule CommsCore.Conversations.GuestAccess.AdmissionVisibilityTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query

  alias CommsCore.{Administration, Conversations, Repo}
  alias CommsCore.Accounts.User
  alias CommsCore.Conversations.{GuestAdmission, Membership}
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :conversation
  @moduletag :guest

  test "expired admissions release conversation quota without a cleanup worker" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, settings} =
             Administration.update_tenant_settings(
               %{version: 1, max_conversation_members: 2},
               subject
             )

    assert settings.settings.max_conversation_members == 2

    assert {:ok, %{token: token}} =
             Conversations.create_guest_link_view(
               account.conversation.id,
               %{expires_in_seconds: 3_600, max_uses: 3},
               subject
             )

    assert {:ok, first} =
             Conversations.redeem_guest_link(token, guest_attrs("First Guest"))

    assert {:error, :conversation_member_quota_exceeded} =
             Conversations.redeem_guest_link(token, guest_attrs("Blocked Guest"))

    expired_at = DateTime.utc_now() |> DateTime.add(-1, :second)
    admitted_at = DateTime.add(expired_at, -1, :second)

    from(admission in GuestAdmission, where: admission.id == ^first.admission.id)
    |> Repo.update_all(set: [admitted_at: admitted_at, expires_at: expired_at])

    assert Conversations.admission_usage(account.tenant.id).largest_conversation_members == 1

    assert {:ok, second} =
             Conversations.redeem_guest_link(token, guest_attrs("Replacement Guest"))

    assert second.admission.id != first.admission.id
  end

  test "expired guest identities disappear from member rosters before worker cleanup" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, %{token: token}} =
             Conversations.create_guest_link_view(
               account.conversation.id,
               %{expires_in_seconds: 3_600},
               subject
             )

    assert {:ok, redemption} =
             Conversations.redeem_guest_link(token, guest_attrs("Expiring Roster Guest"))

    assert {:ok, before_expiry} =
             Conversations.list_member_views(account.conversation.id, subject)

    assert Enum.any?(before_expiry, &(&1.user.id == redemption.authentication.user.id))

    expired_at = DateTime.utc_now() |> DateTime.add(-1, :second)

    from(user in User, where: user.id == ^redemption.authentication.user.id)
    |> Repo.update_all(set: [guest_expires_at: expired_at])

    assert {:ok, after_expiry} =
             Conversations.list_member_views(account.conversation.id, subject)

    refute Enum.any?(after_expiry, &(&1.user.id == redemption.authentication.user.id))

    assert %Membership{left_at: nil} =
             Repo.get_by!(Membership,
               tenant_id: account.tenant.id,
               conversation_id: account.conversation.id,
               user_id: redemption.authentication.user.id
             )
  end

  defp guest_attrs(display_name) do
    %{
      display_name: display_name,
      device: %{name: "Guest browser", platform: "test"},
      request_id: "guest-access-test"
    }
  end
end
