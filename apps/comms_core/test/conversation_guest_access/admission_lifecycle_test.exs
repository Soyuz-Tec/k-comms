defmodule CommsCore.Conversations.GuestAccess.AdmissionLifecycleTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query

  alias CommsCore.{Accounts, Administration, Conversations, Repo}

  alias CommsCore.Accounts.{Session, User}

  alias CommsCore.Conversations.{
    GuestAdmission,
    GuestLink,
    GuestLinkView,
    Membership
  }

  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :conversation
  @moduletag :guest

  test "revocation terminates guest membership, admission, session, and access" do
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
               %{expires_in_seconds: 3_600},
               subject
             )

    assert {:ok, redemption} =
             Conversations.redeem_guest_link(token, guest_attrs("Revoked Guest"))

    session_id = redemption.authentication.session_id
    guest_user_id = redemption.authentication.user.id
    admission_id = redemption.admission.id

    expiry_job =
      Repo.one!(
        from(job in Oban.Job,
          where:
            job.worker == "CommsWorkers.GuestAdmissionExpiryWorker" and
              fragment("?->>'admission_id'", job.args) == ^admission_id
        )
      )

    assert DateTime.compare(expiry_job.scheduled_at, redemption.admission.expires_at) == :eq

    guest_subject = guest_subject(redemption)

    assert {:ok, %{admission_id: ^admission_id}} =
             Conversations.resolve_guest_access(guest_subject, account.conversation.id)

    assert {:ok,
            %{
              guest_link: %GuestLinkView{status: :revoked},
              revoked_session_ids: [^session_id]
            }} =
             Conversations.revoke_guest_link_view(
               account.conversation.id,
               link.id,
               subject
             )

    assert %GuestAdmission{revoked_at: %DateTime{}} =
             Repo.get!(GuestAdmission, admission_id)

    assert %Membership{left_at: %DateTime{}} =
             Repo.get_by!(Membership,
               tenant_id: account.tenant.id,
               conversation_id: account.conversation.id,
               user_id: guest_user_id
             )

    assert %Session{revoked_at: %DateTime{}} = Repo.get!(Session, session_id)

    assert {:error, :forbidden} =
             Conversations.resolve_guest_access(guest_subject, account.conversation.id)

    assert {:error, :forbidden} =
             Conversations.guest_scope_for_session(session_id)

    assert {:error, :guest_link_unavailable} =
             Conversations.preview_guest_link(token)
  end

  @tag :concurrency
  test "max-use redemption remains exact under concurrency" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, %{guest_link: link, token: token}} =
             Conversations.create_guest_link_view(
               account.conversation.id,
               %{expires_in_seconds: 3_600, max_uses: 1},
               subject
             )

    results =
      1..6
      |> Task.async_stream(
        fn number ->
          Conversations.redeem_guest_link(
            token,
            guest_attrs("Concurrent Guest #{number}")
          )
        end,
        max_concurrency: 6,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.count(
             results,
             &match?({:error, :guest_link_unavailable}, &1)
           ) == 5

    assert Repo.get!(GuestLink, link.id).use_count == 1

    assert Repo.aggregate(
             from(admission in GuestAdmission,
               where: admission.guest_link_id == ^link.id
             ),
             :count
           ) == 1
  end

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
end
