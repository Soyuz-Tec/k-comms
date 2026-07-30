defmodule CommsCore.Conversations.GuestAccess.LinkRevocationTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query

  alias CommsCore.{Accounts, Conversations, Repo}
  alias CommsCore.Accounts.Session

  alias CommsCore.Conversations.{
    GuestAdmission,
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
