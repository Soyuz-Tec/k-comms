defmodule CommsCore.AudioCalls.LifecycleTest do
  use CommsCore.DataCase, async: false

  @moduletag :call
  @moduletag :integration

  alias CommsCore.Accounts
  alias CommsCore.Administration
  alias CommsCore.Administration.TenantSettings
  alias CommsCore.AudioCalls
  alias CommsCore.AudioCalls.{AudioCall, AudioCallParticipant, CallView}
  alias CommsCore.Audit
  alias CommsCore.Conversations
  alias CommsCore.Conversations.Membership
  alias CommsCore.Events.OutboxEvent
  alias CommsTestSupport.Fixtures

  test "video calls use the same lifecycle for direct and group conversations" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    member = signed_in_member(account)

    assert {:ok, direct} =
             Conversations.create(
               %{kind: "direct", member_ids: [member.user.id]},
               subject
             )

    assert {:ok, group_call, :created} =
             AudioCalls.start(account.conversation.id, subject, :video)

    assert {:ok, direct_call, :created} = AudioCalls.start(direct.id, subject, :video)
    assert group_call.media_kind == :video
    assert direct_call.media_kind == :video

    assert {:ok, joined_call, :joined} =
             AudioCalls.with_join_authorized(
               direct.id,
               direct_call.id,
               member.subject,
               fn _request -> {:ok, :joined} end
             )

    assert joined_call.id == direct_call.id
    refute joined_call.can_end
  end

  test "video authorization is independently tenant controlled" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    settings = Repo.get_by(TenantSettings, tenant_id: account.tenant.id)

    (settings || %TenantSettings{tenant_id: account.tenant.id})
    |> TenantSettings.changeset(%{allow_video_calls: false})
    |> Repo.insert_or_update!()

    assert {:error, :video_calls_disabled} =
             AudioCalls.start(account.conversation.id, subject, :video)

    assert {:ok, audio_call, :created} = AudioCalls.start(account.conversation.id, subject)
    assert audio_call.media_kind == :audio
  end

  test "active-call media checks operate on the public call projection" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, call, :created} =
             AudioCalls.start(account.conversation.id, subject, :video)

    assert {:ok, %CallView{id: call_id, media_kind: :video}} =
             AudioCalls.get_active(account.conversation.id, subject, :video)

    assert call_id == call.id

    assert {:error, :call_media_kind_conflict} =
             AudioCalls.get_active(account.conversation.id, subject, :audio)
  end

  test "tenant video disable revokes only video admissions and denies future joins" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    member = Fixtures.user_fixture(account)

    assert {:ok, direct} =
             Conversations.create(%{kind: "direct", member_ids: [member.user.id]}, subject)

    assert {:ok, video_call, :created} =
             AudioCalls.start(account.conversation.id, subject, :video)

    assert {:ok, audio_call, :created} = AudioCalls.start(direct.id, subject)

    issuer = fn request -> {:ok, request.participant_id} end

    assert {:ok, ^video_call, video_participant_id} =
             AudioCalls.with_join_authorized(
               account.conversation.id,
               video_call.id,
               subject,
               issuer
             )

    assert {:ok, ^audio_call, audio_participant_id} =
             AudioCalls.with_join_authorized(direct.id, audio_call.id, subject, issuer)

    assert {:ok, %{settings: %{allow_video_calls: false, allow_audio_calls: true}}} =
             Administration.update_tenant_settings(
               %{version: 1, allow_video_calls: false},
               subject
             )

    assert Repo.get!(AudioCallParticipant, video_participant_id).status == :revoked

    assert Repo.get!(AudioCallParticipant, video_participant_id).revocation_reason ==
             "tenant_video_disabled"

    assert Repo.get!(AudioCallParticipant, audio_participant_id).status == :admitted

    assert {:error, :video_calls_disabled} =
             AudioCalls.authorize_join(account.conversation.id, video_call.id, subject)

    assert {:ok, ^audio_call} = AudioCalls.authorize_join(direct.id, audio_call.id, subject)
  end

  test "legacy expected-kind joins cannot issue a video credential" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject, :video)

    assert {:error, :call_media_kind_conflict} =
             AudioCalls.with_join_authorized(
               account.conversation.id,
               call.id,
               subject,
               :audio,
               fn _request -> flunk("legacy audio issuer must not run") end
             )

    assert {:ok, ^call, :video_credential} =
             AudioCalls.with_join_authorized(
               account.conversation.id,
               call.id,
               subject,
               fn request ->
                 assert request.media_kind == :video
                 {:ok, :video_credential}
               end
             )
  end

  test "atomic start and starter credential issuance roll back every new-call artifact" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:error, :credential_issuer_failed} =
             AudioCalls.start_with_join_authorized(
               account.conversation.id,
               subject,
               :video,
               fn _call -> :ok end,
               fn _request -> {:error, :credential_issuer_failed} end
             )

    assert_no_call_start_artifacts(account.tenant.id)
  end

  test "an expired call is not joinable and the next start replaces it" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)

    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    AudioCall
    |> where([record], record.id == ^call.id)
    |> Repo.update_all(
      set: [started_at: DateTime.add(timestamp, -3_600), expires_at: DateTime.add(timestamp, -1)]
    )

    assert {:error, :audio_call_expired} =
             AudioCalls.authorize_join(account.conversation.id, call.id, subject)

    test_pid = self()
    persisted_call = Repo.get!(AudioCall, call.id)

    assert {:ok, replacement, :created} =
             AudioCalls.start(account.conversation.id, subject, fn expired_call ->
               send(test_pid, {:deleted_expired_provider_room, expired_call})
               :ok
             end)

    assert_receive {:deleted_expired_provider_room, deleted_call}
    assert deleted_call.id == call.id
    assert deleted_call.provider_room == persisted_call.provider_room
    assert deleted_call.status == :ending
    refute replacement.id == call.id
    assert Repo.get!(AudioCall, call.id).status == :ended
  end

  test "provider failure rolls back expired replacement and leaves the old call recoverable" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)

    timestamp = now()

    AudioCall
    |> where([record], record.id == ^call.id)
    |> Repo.update_all(
      set: [started_at: DateTime.add(timestamp, -3_600), expires_at: DateTime.add(timestamp, -1)]
    )

    assert {:error, :audio_provider_unavailable} =
             AudioCalls.start(account.conversation.id, subject, fn ending_call ->
               assert ending_call.status == :ending
               {:error, :audio_provider_unavailable}
             end)

    persisted = Repo.get!(AudioCall, call.id)
    assert persisted.status == :active
    assert is_nil(persisted.ended_at)
    assert Repo.aggregate(AudioCall, :count) == 1

    refute Audit.get_by(%{
             tenant_id: account.tenant.id,
             resource_id: call.id,
             action: "audio_call.end"
           })
  end

  test "tenant disablement, cross-tenant access, membership removal, and session revocation fail closed" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    settings = Repo.get_by(TenantSettings, tenant_id: account.tenant.id)

    (settings || %TenantSettings{tenant_id: account.tenant.id})
    |> TenantSettings.changeset(%{allow_audio_calls: false})
    |> Repo.insert_or_update!()

    assert {:error, :audio_calls_disabled} = AudioCalls.start(account.conversation.id, subject)

    Repo.get_by!(TenantSettings, tenant_id: account.tenant.id)
    |> TenantSettings.changeset(%{allow_audio_calls: true})
    |> Repo.update!()

    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)
    other = Fixtures.account_fixture()

    assert {:error, :forbidden} =
             AudioCalls.authorize_join(
               account.conversation.id,
               call.id,
               Fixtures.subject(other)
             )

    membership =
      Repo.get_by!(Membership,
        conversation_id: account.conversation.id,
        user_id: account.user.id
      )

    membership |> Membership.changeset(%{left_at: now()}) |> Repo.update!()

    assert {:error, :forbidden} =
             AudioCalls.authorize_join(account.conversation.id, call.id, subject)

    membership |> Membership.changeset(%{left_at: nil}) |> Repo.update!()
    assert :ok = Accounts.revoke_session(account.session.id, account.user.id)

    assert {:error, :forbidden} =
             AudioCalls.authorize_join(account.conversation.id, call.id, subject)
  end

  test "starter and conversation moderators may end while ordinary members may not" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    member = signed_in_member(account)

    assert {:ok, membership} =
             Conversations.add_member(
               account.conversation.id,
               member.user.id,
               :member,
               subject
             )

    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)

    assert {:error, :forbidden} =
             AudioCalls.end_call(
               account.conversation.id,
               call.id,
               %{},
               member.subject,
               fn _call -> :ok end
             )

    membership |> Membership.changeset(%{role: :moderator}) |> Repo.update!()

    assert {:ok, ended} =
             AudioCalls.end_call(
               account.conversation.id,
               call.id,
               %{reason: "moderator_ended"},
               member.subject,
               fn _call -> :ok end
             )

    assert ended.status == :ended
    assert ended.ended_by_user_id == member.user.id
    assert ended.end_reason == "moderator_ended"
  end

  test "end authorization validates and normalizes the reason before provider orchestration" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)

    assert {:error, :invalid_end_reason} =
             AudioCalls.authorize_end(
               account.conversation.id,
               call.id,
               %{reason: "  "},
               subject
             )

    assert {:ok, authorized_call, "owner_ended"} =
             AudioCalls.authorize_end(
               account.conversation.id,
               call.id,
               %{reason: "  owner_ended  "},
               subject
             )

    assert authorized_call.id == call.id
    assert Repo.get!(AudioCall, call.id).status == :active
  end

  test "provider failure rolls the ending transition back to active without end evidence" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)

    assert {:error, :audio_provider_unavailable} =
             AudioCalls.end_call(
               account.conversation.id,
               call.id,
               %{reason: "owner_ended"},
               subject,
               fn ending_call ->
                 assert ending_call.status == :ending
                 {:error, :audio_provider_unavailable}
               end
             )

    persisted = Repo.get!(AudioCall, call.id)
    assert persisted.status == :active
    assert is_nil(persisted.ended_at)
    assert is_nil(persisted.end_reason)

    refute Audit.get_by(%{
             tenant_id: account.tenant.id,
             resource_id: call.id,
             action: "audio_call.end"
           })

    refute Repo.get_by(OutboxEvent,
             aggregate_id: call.id,
             event_type: "audio_call.ended.v1"
           )
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

  defp assert_no_call_start_artifacts(tenant_id) do
    assert Repo.aggregate(AudioCall, :count) == 0
    assert Repo.aggregate(AudioCallParticipant, :count) == 0

    assert Repo.aggregate(
             from(event in OutboxEvent,
               where: event.event_type in ["call.started.v1", "audio_call.started.v1"]
             ),
             :count
           ) == 0

    assert Audit.count(%{tenant_id: tenant_id, action: "audio_call.start"}) == 0
    assert Audit.count(%{tenant_id: tenant_id, action: "video_call.start"}) == 0

    assert Repo.aggregate(
             from(job in Oban.Job,
               where: job.worker == "CommsWorkers.AudioCallExpiryWorker"
             ),
             :count
           ) == 0
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
