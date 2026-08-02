defmodule CommsCore.AudioCalls.CollaborationTest do
  use CommsCore.DataCase, async: false

  @moduletag :call
  @moduletag :integration

  import Ecto.Query

  alias CommsCore.{Accounts, AudioCalls, Audit, Conversations, Repo}
  alias CommsCore.AudioCalls.AudioCallParticipant
  alias CommsTestSupport.Fixtures

  test "participants raise hands and moderators atomically remove another admission" do
    account = Fixtures.account_fixture()
    owner_subject = Fixtures.subject(account)
    member = signed_in_member(account)

    assert {:ok, _membership} =
             Conversations.add_member(
               account.conversation.id,
               member.user.id,
               :member,
               owner_subject
             )

    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, owner_subject)
    admit!(account.conversation.id, call.id, owner_subject)
    member_identity = admit!(account.conversation.id, call.id, member.subject)

    participant_before =
      Repo.get_by!(AudioCallParticipant,
        audio_call_id: call.id,
        session_id: member.subject.session_id
      )

    assert :ok =
             AudioCalls.authorize_participant(
               account.conversation.id,
               call.id,
               member.subject
             )

    participant_after = Repo.get!(AudioCallParticipant, participant_before.id)
    assert participant_after.credential_issue_count == participant_before.credential_issue_count
    assert participant_after.updated_at == participant_before.updated_at

    assert {:ok, raised} =
             AudioCalls.set_hand(account.conversation.id, call.id, true, member.subject)

    assert raised.user_id == member.user.id
    assert raised.hand_raised

    assert {:ok, participants} =
             AudioCalls.list_participants(account.conversation.id, call.id, owner_subject)

    assert Enum.any?(participants, &(&1.user_id == member.user.id and &1.hand_raised))

    assert {:error, :forbidden} =
             AudioCalls.remove_participant(
               account.conversation.id,
               call.id,
               member_identity,
               member.subject
             )

    assert {:ok, target} =
             AudioCalls.remove_participant(
               account.conversation.id,
               call.id,
               member_identity,
               owner_subject
             )

    participant = Repo.get!(AudioCallParticipant, target.participant_id)
    assert participant.status == :revoked
    assert participant.revocation_reason == "moderator_removed"
    assert participant.eviction_status == :pending

    assert Repo.exists?(
             from(job in Oban.Job,
               where:
                 job.worker == "CommsWorkers.AudioParticipantEvictionWorker" and
                   fragment("?->>'participant_id'", job.args) == ^participant.id
             )
           )

    assert Audit.count(%{
             tenant_id: account.tenant.id,
             action: "call.participant_removed"
           }) == 1

    assert {:error, :forbidden} =
             AudioCalls.authorize_participant(
               account.conversation.id,
               call.id,
               member.subject
             )
  end

  defp admit!(conversation_id, call_id, subject) do
    assert {:ok, _call, identity} =
             AudioCalls.with_join_authorized(
               conversation_id,
               call_id,
               subject,
               fn request -> {:ok, request.provider_identity} end
             )

    identity
  end

  defp signed_in_member(account) do
    member = Fixtures.user_fixture(account)
    [local, _domain] = String.split(member.user.email, "@", parts: 2)
    suffix = String.replace_prefix(local, "member-", "")

    {:ok, signed_in} =
      Accounts.authenticate_view(
        account.tenant.slug,
        member.user.email,
        "correct-horse-battery-#{suffix}",
        %{name: "Member browser", platform: "test"}
      )

    {:ok, access_context} = Accounts.access_context(signed_in.session_id)
    %{user: signed_in.user, subject: access_context.subject}
  end
end
