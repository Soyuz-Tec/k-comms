defmodule CommsWorkers.GuestAdmissionExpiryWorkerTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query

  alias CommsCore.{Accounts, AudioCalls, Conversations, Repo}
  alias CommsCore.Accounts.{Session, User}
  alias CommsCore.AudioCalls.{AudioCallParticipant, CredentialRequest}
  alias CommsCore.Conversations.{GuestAdmission, GuestLink, Membership}
  alias CommsTestSupport.Fixtures
  alias CommsWorkers.GuestAdmissionExpiryWorker

  test "not-due, malformed, and unknown jobs fail closed without changing admission" do
    {account, _link, redemption} = redeem_guest("Not Due Guest")
    admission_id = redemption.admission.id

    assert {:error, :forbidden} =
             Conversations.expire_guest_admission(admission_id, __MODULE__)

    assert {:snooze, seconds} =
             GuestAdmissionExpiryWorker.perform(%Oban.Job{
               args: %{"admission_id" => admission_id}
             })

    assert seconds > 0
    assert Repo.get!(GuestAdmission, admission_id).revoked_at == nil
    assert Accounts.active_user_count(account.tenant.id) == 2

    assert {:discard, :admission_id_required} =
             GuestAdmissionExpiryWorker.perform(%Oban.Job{args: %{}})

    assert {:discard, :guest_admission_not_found} =
             GuestAdmissionExpiryWorker.perform(%Oban.Job{
               args: %{"admission_id" => Ecto.UUID.generate()}
             })
  end

  test "expiry idempotently removes roster, identity quota, session, and active call access" do
    {account, link, redemption} = redeem_guest("Expired Worker Guest")
    guest_subject = guest_subject(redemption)

    assert {:ok, call, :created} =
             AudioCalls.start(account.conversation.id, Fixtures.subject(account))

    assert {:ok, _joined_call, _credential} =
             AudioCalls.with_join_authorized(
               account.conversation.id,
               call.id,
               guest_subject,
               fn %CredentialRequest{provider_identity: identity} -> {:ok, identity} end
             )

    participant =
      Repo.get_by!(AudioCallParticipant,
        audio_call_id: call.id,
        user_id: redemption.authentication.user.id
      )

    expire_redemption!(link.id, redemption)

    job = %Oban.Job{args: %{"admission_id" => redemption.admission.id}}
    assert :ok = GuestAdmissionExpiryWorker.perform(job)
    assert :ok = GuestAdmissionExpiryWorker.perform(job)

    assert %GuestAdmission{revoked_at: %DateTime{}} =
             Repo.get!(GuestAdmission, redemption.admission.id)

    assert %Membership{left_at: %DateTime{}} =
             Repo.get!(Membership, redemption.admission.membership_id)

    assert %Session{revoked_at: %DateTime{}} =
             Repo.get!(Session, redemption.authentication.session_id)

    assert Accounts.active_user_count(account.tenant.id) == 1

    assert %AudioCallParticipant{
             status: :revoked,
             revocation_reason: "guest_admission_expired",
             eviction_status: :pending
           } = Repo.get!(AudioCallParticipant, participant.id)

    assert {:error, :forbidden} =
             Conversations.resolve_guest_access(guest_subject, account.conversation.id)

    assert {:ok, members} =
             Conversations.list_member_views(
               account.conversation.id,
               Fixtures.subject(account)
             )

    refute Enum.any?(members, &(&1.user.id == redemption.authentication.user.id))
  end

  test "explicit link revocation wins safely before its scheduled expiry job" do
    {account, link, redemption} = redeem_guest("Revoked Before Worker")

    assert {:ok,
            %{
              guest_link: %{status: :revoked},
              revoked_session_ids: [session_id]
            }} =
             Conversations.revoke_guest_link_view(
               account.conversation.id,
               link.id,
               Fixtures.subject(account)
             )

    assert session_id == redemption.authentication.session_id

    assert :ok =
             GuestAdmissionExpiryWorker.perform(%Oban.Job{
               args: %{"admission_id" => redemption.admission.id}
             })
  end

  defp redeem_guest(display_name) do
    account = Fixtures.account_fixture()

    assert {:ok, %{guest_link: link, token: token}} =
             Conversations.create_guest_link_view(
               account.conversation.id,
               %{expires_in_seconds: 3_600, max_uses: 1},
               Fixtures.subject(account)
             )

    assert {:ok, redemption} =
             Conversations.redeem_guest_link(token, %{
               display_name: display_name,
               device: %{name: "Guest browser", platform: "test"},
               request_id: "guest-expiry-worker-test"
             })

    {account, link, redemption}
  end

  defp guest_subject(redemption) do
    assert {:ok, context} =
             Accounts.guest_access_context(
               redemption.authentication.session_id,
               "guest-expiry-worker-test"
             )

    Map.merge(context.subject, %{
      guest_admission_id: redemption.admission.id,
      guest_conversation_id: redemption.conversation.id,
      guest_history_from_sequence: redemption.admission.history_from_sequence
    })
  end

  defp expire_redemption!(link_id, redemption) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    inserted_at = DateTime.add(timestamp, -7_200, :second)
    admitted_at = DateTime.add(timestamp, -3_600, :second)
    expired_at = DateTime.add(timestamp, -1, :second)

    from(link in GuestLink, where: link.id == ^link_id)
    |> Repo.update_all(set: [inserted_at: inserted_at, expires_at: expired_at])

    from(admission in GuestAdmission, where: admission.id == ^redemption.admission.id)
    |> Repo.update_all(set: [admitted_at: admitted_at, expires_at: expired_at])

    from(user in User, where: user.id == ^redemption.authentication.user.id)
    |> Repo.update_all(set: [guest_expires_at: expired_at])
  end
end
