defmodule CommsCore.ServiceAccountsTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Accounts, Conversations, PasswordRecovery, Repo, ServiceAccounts}
  alias CommsCore.Accounts.Device
  alias CommsCore.Audit.AuditEvent
  alias CommsCore.ServiceAccounts.{ServiceAccount, ServiceUser}
  alias CommsTestSupport.Fixtures

  test "credentials are one-time, versioned, human-login isolated, and revoked atomically" do
    owner = Fixtures.account_fixture()
    subject = Fixtures.subject(owner)

    attrs = %{
      name: "Release Bot",
      scopes: ["conversations:read", "messages:read", "messages:write"],
      reason: "Automate release notices"
    }

    assert {:error, :step_up_required} = ServiceAccounts.create(attrs, subject)
    subject = Fixtures.step_up(owner, subject)

    assert {:ok, created} = ServiceAccounts.create(attrs, subject)
    assert created.credential =~ ~r/^kcsa_[0-9a-f-]{36}\.[A-Za-z0-9_-]{43}$/
    account = created.service_account
    refute account.secret_hash == :crypto.hash(:sha256, created.credential)
    refute inspect(account) =~ created.credential

    service_user = Repo.get!(ServiceUser, account.user_id)
    device = Repo.get!(Device, account.device_id)
    assert service_user.account_type == :service
    assert service_user.role == :member
    assert service_user.status == :active
    assert service_user.password_hash == nil
    assert service_user.email == "#{account.id}@service.invalid"
    assert device.platform == "service_account"

    assert {:error, :invalid_credentials} =
             Accounts.authenticate(owner.tenant.slug, service_user.email, "any-password")

    assert {:error, :not_found} =
             Accounts.change_user(
               service_user.id,
               %{status: "suspended", version: service_user.lock_version, reason: "generic path"},
               subject
             )

    assert {:error, :forbidden} =
             Accounts.create_invitation(
               %{email: service_user.email, role: "member", idempotency_key: "bot-invite"},
               subject
             )

    assert :ok =
             PasswordRecovery.request(%{
               tenant_slug: owner.tenant.slug,
               email: service_user.email
             })

    assert Repo.aggregate(
             from(request in CommsCore.Accounts.PasswordRecoveryRequest,
               where: request.user_id == ^service_user.id
             ),
             :count
           ) == 0

    assert {:ok, service_subject} = ServiceAccounts.authenticate(created.credential)
    assert service_subject.auth_type == :service
    assert {:error, :invalid_service_token} = ServiceAccounts.authenticate("not-a-service-token")

    [prefix, _secret] = String.split(created.credential, ".", parts: 2)
    wrong = prefix <> "." <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
    assert {:error, :invalid_service_token} = ServiceAccounts.authenticate(wrong)

    assert {:error, :stale_version} =
             ServiceAccounts.rotate(account.id, %{version: 99, reason: "stale rotation"}, subject)

    assert {:ok, rotated} =
             ServiceAccounts.rotate(
               account.id,
               %{version: account.lock_version, reason: "scheduled credential rotation"},
               subject
             )

    assert rotated.credential != created.credential
    assert {:error, :invalid_service_token} = ServiceAccounts.authenticate(created.credential)
    assert {:ok, rotated_subject} = ServiceAccounts.authenticate(rotated.credential)
    assert rotated_subject.credential_generation == 2

    assert {:ok, revoked} =
             ServiceAccounts.revoke(
               account.id,
               %{version: rotated.service_account.lock_version, reason: "automation retired"},
               subject
             )

    assert revoked.status == :revoked
    assert revoked.lock_version == 3
    assert {:error, :invalid_service_token} = ServiceAccounts.authenticate(rotated.credential)
    assert Repo.get!(ServiceUser, account.user_id).status == :suspended
    refute is_nil(Repo.get!(Device, account.device_id).revoked_at)

    audit_text =
      AuditEvent
      |> where([event], event.resource_id == ^account.id)
      |> Repo.all()
      |> Enum.map_join(" ", &inspect(&1.metadata))

    refute audit_text =~ "kcsa_"
    refute audit_text =~ "secret_hash"
    refute audit_text =~ created.credential
    refute audit_text =~ rotated.credential
  end

  test "service commands recheck scopes, active membership, tenant, and idempotent sender identity" do
    owner = Fixtures.account_fixture()
    subject = Fixtures.step_up(owner)

    assert {:ok, created} =
             ServiceAccounts.create(
               %{
                 name: "Conversation Bot",
                 scopes: [
                   "conversations:read",
                   "messages:read",
                   "messages:write",
                   "search:read"
                 ],
                 reason: "Exercise scoped messaging"
               },
               subject
             )

    bot_id = created.service_account.user_id

    assert {:ok, _membership} =
             Conversations.add_member(owner.conversation.id, bot_id, :member, subject)

    assert {:ok, service_subject} = ServiceAccounts.authenticate(created.credential)

    assert {:ok, conversations} = ServiceAccounts.list_conversations(service_subject)
    assert Enum.any?(conversations, &(&1.conversation.id == owner.conversation.id))

    message_attrs = %{
      client_message_id: "service-idempotency-0001",
      body: "Release 42 is ready",
      metadata: %{"source" => "release-bot"}
    }

    assert {:ok, first, :created} =
             ServiceAccounts.send_message(owner.conversation.id, message_attrs, service_subject)

    assert first.sender_user_id == bot_id
    assert first.sender_device_id == created.service_account.device_id

    assert {:ok, replay, :duplicate} =
             ServiceAccounts.send_message(owner.conversation.id, message_attrs, service_subject)

    assert replay.id == first.id

    assert {:ok, history} =
             ServiceAccounts.list_messages(owner.conversation.id, service_subject, limit: 20)

    assert Enum.any?(history, &(&1.id == first.id))
    assert {:ok, search} = ServiceAccounts.search("Release 42", service_subject)
    assert Enum.any?(search, &(&1.id == first.id))

    assert {:ok, private_conversation} =
             Conversations.create(
               %{kind: "group", title: "Humans only", visibility: "private", member_ids: []},
               subject
             )

    assert {:error, :forbidden} =
             ServiceAccounts.list_messages(private_conversation.id, service_subject)

    assert {:error, :forbidden} =
             ServiceAccounts.send_message(private_conversation.id, message_attrs, service_subject)

    other_tenant = Fixtures.account_fixture()

    assert {:error, :forbidden} =
             ServiceAccounts.list_messages(other_tenant.conversation.id, service_subject)
  end

  test "each service endpoint capability fails closed when its scope is absent" do
    owner = Fixtures.account_fixture()
    subject = Fixtures.step_up(owner)

    assert {:ok, created} =
             ServiceAccounts.create(
               %{
                 name: "Read Directory Bot",
                 scopes: ["conversations:read"],
                 reason: "List joined conversations only"
               },
               subject
             )

    assert {:ok, _membership} =
             Conversations.add_member(
               owner.conversation.id,
               created.service_account.user_id,
               :member,
               subject
             )

    assert {:ok, service_subject} = ServiceAccounts.authenticate(created.credential)
    assert {:ok, _} = ServiceAccounts.list_conversations(service_subject)

    assert {:error, :forbidden} =
             ServiceAccounts.list_messages(owner.conversation.id, service_subject)

    assert {:error, :forbidden} =
             ServiceAccounts.send_message(
               owner.conversation.id,
               %{client_message_id: "wrong-scope-0001", body: "blocked"},
               service_subject
             )

    assert {:error, :forbidden} = ServiceAccounts.search("blocked", service_subject)
  end

  test "expiry is bounded and cleanup disables the durable bot identity" do
    owner = Fixtures.account_fixture()
    subject = Fixtures.step_up(owner)
    too_late = DateTime.utc_now() |> DateTime.add(366 * 24 * 60 * 60, :second)

    assert {:error, :invalid_datetime} =
             ServiceAccounts.create(
               %{
                 name: "Long-lived Bot",
                 scopes: ["messages:read"],
                 expires_at: too_late,
                 reason: "Invalid overlong credential"
               },
               subject
             )

    assert {:ok, created} =
             ServiceAccounts.create(
               %{
                 name: "Expiring Bot",
                 scopes: ["messages:read"],
                 reason: "Validate expiry cleanup"
               },
               subject
             )

    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    inserted_at = DateTime.add(timestamp, -120, :second)
    expired_at = DateTime.add(timestamp, -60, :second)

    from(account in ServiceAccount, where: account.id == ^created.service_account.id)
    |> Repo.update_all(set: [inserted_at: inserted_at, expires_at: expired_at])

    assert {:error, :invalid_service_token} = ServiceAccounts.authenticate(created.credential)
    assert {:ok, [expired]} = ServiceAccounts.list(subject)
    assert expired.status == :expired
    assert Repo.get!(ServiceUser, expired.user_id).status == :suspended
    refute is_nil(Repo.get!(Device, expired.device_id).revoked_at)
  end
end
