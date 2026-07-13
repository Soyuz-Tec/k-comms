defmodule CommsCore.AdmissionQuotasTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Administration.Invitation

  alias CommsCore.{
    Accounts,
    AdmissionQuotas,
    Administration,
    Conversations,
    Repo,
    ServiceAccounts
  }

  alias CommsTestSupport.Fixtures

  test "active identity admission is race-safe and includes service identities" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    set_limits!(subject, %{max_active_users: 2})

    results =
      1..2
      |> Task.async_stream(
        fn index ->
          Accounts.create_user(
            %{
              display_name: "Concurrent member #{index}",
              email:
                "concurrent-member-#{index}-#{System.unique_integer([:positive])}@example.test",
              password: "correct-horse-concurrent-member-#{index}",
              role: "member"
            },
            subject
          )
        end,
        max_concurrency: 2,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :active_user_quota_exceeded}, &1)) == 1

    assert %{
             active_users: 2,
             at_capacity: %{active_users: true, any: true},
             over_limit: %{any: false}
           } =
             AdmissionQuotas.usage(account.tenant.id)

    service_tenant = Fixtures.account_fixture()
    service_subject = Fixtures.step_up(service_tenant)
    set_limits!(service_subject, %{max_active_users: 2})

    assert {:ok, _created} =
             ServiceAccounts.create(
               %{
                 name: "Capacity bot",
                 scopes: ["conversations:read"],
                 expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
                 reason: "Verify shared identity capacity"
               },
               service_subject
             )

    assert %{active_users: 2} = AdmissionQuotas.usage(service_tenant.tenant.id)

    assert {:error, :active_user_quota_exceeded} =
             create_member(service_subject, "blocked-after-service")
  end

  test "direct creation, invitation acceptance, and audited admin unsuspend share one active identity limit" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    settings = set_limits!(subject, %{max_active_users: 3})

    assert {:ok, member} = create_member(subject, "reactivation-target")

    assert {:ok, suspended} =
             Accounts.change_user(
               member.id,
               %{version: member.lock_version, status: "suspended", reason: "Capacity test"},
               subject
             )

    set_limits!(subject, %{version: settings.lock_version, max_active_users: 1})

    assert {:error, :active_user_quota_exceeded} = create_member(subject, "direct-blocked")

    assert {:ok, invitation_result} =
             Accounts.create_invitation(
               %{
                 email: "quota-invited-#{System.unique_integer([:positive])}@example.test",
                 role: "member",
                 idempotency_key: "quota-invite-#{System.unique_integer([:positive])}"
               },
               subject
             )

    assert {:error, :active_user_quota_exceeded} =
             Accounts.accept_invitation(%{
               token: invitation_result.token,
               display_name: "Quota invited",
               password: "correct-horse-quota-invited"
             })

    assert Repo.get!(Invitation, invitation_result.invitation.id).status == :pending

    assert {:error, :invitation_identity_conflict} =
             Accounts.create_invitation(
               %{
                 email: suspended.email,
                 role: "member",
                 idempotency_key: "quota-reactivation-#{System.unique_integer([:positive])}"
               },
               subject
             )

    assert {:error, :active_user_quota_exceeded} =
             Accounts.change_user(
               suspended.id,
               %{version: suspended.lock_version, status: "active", reason: "Capacity test"},
               subject
             )

    set_limits!(subject, %{max_active_users: 2})

    assert {:ok, reactivated} =
             Accounts.change_user(
               suspended.id,
               %{
                 version: suspended.lock_version,
                 status: "active",
                 reason: "Audited admin reactivation"
               },
               subject
             )

    assert reactivated.id == suspended.id
    assert reactivated.status == :active
    assert reactivated.lock_version == suspended.lock_version + 1
  end

  test "active conversation admission is race-safe and archived conversations release capacity" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    set_limits!(subject, %{max_active_conversations: 2})

    results =
      1..2
      |> Task.async_stream(
        fn index ->
          Conversations.create(%{kind: "group", title: "Concurrent #{index}"}, subject)
        end,
        max_concurrency: 2,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, created}] = Enum.filter(results, &match?({:ok, _}, &1))

    assert Enum.count(
             results,
             &match?({:error, :active_conversation_quota_exceeded}, &1)
           ) == 1

    assert {:ok, _archived} = Conversations.archive(created.id, %{version: 1}, subject)

    assert {:ok, _replacement} =
             Conversations.create(%{kind: "group", title: "Replacement"}, subject)

    assert %{active_conversations: 2, over_limit: %{active_conversations: false}} =
             AdmissionQuotas.usage(account.tenant.id)
  end

  test "initial membership, member add, public self-join, and rejoin enforce one member limit" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    set_limits!(subject, %{max_conversation_members: 2, max_active_conversations: 20})

    {first, first_password} = create_member_with_password!(subject, "first-member")
    {second, second_password} = create_member_with_password!(subject, "second-member")

    assert {:error, :conversation_member_quota_exceeded} =
             Conversations.create(
               %{kind: "group", title: "Too many initially", member_ids: [first.id, second.id]},
               subject
             )

    assert {:ok, managed} =
             Conversations.create(%{kind: "channel", title: "Managed capacity"}, subject)

    add_results =
      [first.id, second.id]
      |> Task.async_stream(
        &Conversations.add_member(managed.id, &1, :member, subject),
        max_concurrency: 2,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(add_results, &match?({:ok, _}, &1)) == 1

    assert Enum.count(
             add_results,
             &match?({:error, :conversation_member_quota_exceeded}, &1)
           ) == 1

    assert {:ok, public_channel} =
             Conversations.create(
               %{kind: "channel", title: "Public capacity", visibility: "tenant"},
               subject
             )

    first_subject = login_subject(account, first, first_password, "First quota browser")
    second_subject = login_subject(account, second, second_password, "Second quota browser")

    assert {:ok, first_join} = Conversations.join_public_channel(public_channel.id, first_subject)

    assert {:ok, _left} =
             Conversations.leave_public_channel(
               public_channel.id,
               %{version: first_join.membership.lock_version},
               first_subject
             )

    assert {:ok, _second_join} =
             Conversations.join_public_channel(public_channel.id, second_subject)

    assert {:error, :conversation_member_quota_exceeded} =
             Conversations.join_public_channel(public_channel.id, first_subject)
  end

  test "usage reports an explicit over-limit state after a safe limit reduction" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    assert {:ok, _member} = create_member(subject, "usage-member")

    set_limits!(subject, %{max_active_users: 1})

    assert %{
             active_users: 2,
             limits: %{max_active_users: 1},
             over_limit: %{active_users: true, any: true}
           } = AdmissionQuotas.usage(account.tenant.id)
  end

  defp set_limits!(subject, attrs) do
    version = Map.get(attrs, :version, current_version(subject.tenant_id))

    assert {:ok, result} =
             Administration.update_tenant_settings(Map.put(attrs, :version, version), subject)

    result.settings
  end

  defp current_version(tenant_id) do
    case Repo.get_by(CommsCore.Administration.TenantSettings, tenant_id: tenant_id) do
      nil -> 1
      settings -> settings.lock_version
    end
  end

  defp create_member(subject, label) do
    {user, _password} = create_member_attrs(label)
    Accounts.create_user(user, subject)
  end

  defp create_member_with_password!(subject, label) do
    {attrs, password} = create_member_attrs(label)
    assert {:ok, user} = Accounts.create_user(attrs, subject)
    {user, password}
  end

  defp create_member_attrs(label) do
    suffix = System.unique_integer([:positive, :monotonic])
    password = "correct-horse-#{label}-#{suffix}"

    {%{
       display_name: "Quota #{label} #{suffix}",
       email: "#{label}-#{suffix}@example.test",
       password: password,
       role: "member"
     }, password}
  end

  defp login_subject(account, user, password, device_name) do
    assert {:ok, login} =
             Accounts.authenticate(account.tenant.slug, user.email, password, %{
               name: device_name,
               platform: "test"
             })

    Accounts.subject_for_session(login.session)
  end
end
