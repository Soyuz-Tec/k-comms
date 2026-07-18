defmodule CommsCore.AudioCalls.AuthorizationPolicyTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts.Session
  alias CommsCore.Administration.TenantSettings
  alias CommsCore.AudioCalls.Access
  alias CommsCore.AudioCalls.AuthorizationPolicy
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  @audio_member_actions [:read_audio_call, :start_audio_call, :join_audio_call]
  @video_member_actions [:read_video_call, :start_video_call, :join_video_call]

  test "preflight preserves the Calls action matrix and fails closed" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    resource = %{id: account.conversation.id, started_by_user_id: account.user.id}

    assert :ok = AuthorizationPolicy.authorize(:read_call, subject, resource)

    for action <- @audio_member_actions ++ @video_member_actions do
      assert :ok = AuthorizationPolicy.authorize(action, subject, resource)
    end

    assert :ok = AuthorizationPolicy.authorize(:end_audio_call, subject, resource)
    assert :ok = AuthorizationPolicy.authorize(:end_video_call, subject, resource)

    assert {:error, :forbidden} =
             AuthorizationPolicy.authorize(:undeclared_call_action, subject, resource)
  end

  test "resource, identity, capability, and membership errors retain their precedence" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    (Repo.get_by(TenantSettings, tenant_id: account.tenant.id) ||
       %TenantSettings{tenant_id: account.tenant.id})
    |> TenantSettings.changeset(%{
      allow_audio_calls: false,
      allow_video_calls: false
    })
    |> Repo.insert_or_update!()

    assert {:error, :missing_conversation} =
             AuthorizationPolicy.authorize(:start_audio_call, subject, %{})

    account.session
    |> Session.changeset(%{revoked_at: now()})
    |> Repo.update!()

    assert {:error, :forbidden} =
             AuthorizationPolicy.authorize(:start_audio_call, subject, %{
               id: account.conversation.id
             })
  end

  test "locked access is transaction-only and carries only Calls authorization facts" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:error, :transaction_required} =
             AuthorizationPolicy.lock_access(subject, account.conversation.id, :share)

    assert {:ok, :verified} =
             Repo.transaction(fn ->
               assert {:ok,
                       %Access{
                         tenant_id: tenant_id,
                         user_id: user_id,
                         device_id: device_id,
                         session_id: session_id,
                         conversation_id: conversation_id,
                         membership_role: :owner,
                         allow_audio_calls: true,
                         allow_video_calls: true
                       } = access} =
                        AuthorizationPolicy.lock_access(
                          subject,
                          account.conversation.id,
                          :share
                        )

               assert tenant_id == account.tenant.id
               assert user_id == account.user.id
               assert device_id == account.device.id
               assert session_id == account.session.id
               assert conversation_id == account.conversation.id

               assert :ok =
                        AuthorizationPolicy.authorize_access(
                          :join_audio_call,
                          access,
                          %{conversation_id: conversation_id}
                        )

               assert :ok =
                        AuthorizationPolicy.authorize_access(
                          :end_video_call,
                          access,
                          %{
                            conversation_id: conversation_id,
                            started_by_user_id: account.user.id
                          }
                        )

               assert {:error, :forbidden} =
                        AuthorizationPolicy.authorize_access(
                          :join_audio_call,
                          access,
                          %{conversation_id: Ecto.UUID.generate()}
                        )

               :verified
             end)
  end

  test "locked access captures disabled media flags for the pure post-lock decision" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    (Repo.get_by(TenantSettings, tenant_id: account.tenant.id) ||
       %TenantSettings{tenant_id: account.tenant.id})
    |> TenantSettings.changeset(%{
      allow_audio_calls: false,
      allow_video_calls: true
    })
    |> Repo.insert_or_update!()

    assert {:ok, :verified} =
             Repo.transaction(fn ->
               assert {:ok, %Access{} = access} =
                        AuthorizationPolicy.lock_access(
                          subject,
                          account.conversation.id,
                          :update
                        )

               assert {:error, :audio_calls_disabled} =
                        AuthorizationPolicy.authorize_access(
                          :start_audio_call,
                          access,
                          %{id: account.conversation.id}
                        )

               assert :ok =
                        AuthorizationPolicy.authorize_access(
                          :start_video_call,
                          access,
                          %{id: account.conversation.id}
                        )

               :verified
             end)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
