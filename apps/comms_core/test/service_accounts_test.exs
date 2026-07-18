defmodule CommsCore.ServiceAccountsTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{
    Accounts,
    Administration,
    Audit,
    Conversations,
    Messaging,
    PasswordRecovery,
    Repo,
    ServiceAccounts
  }

  alias CommsCore.Accounts.{Device, User}
  alias CommsCore.Administration.Tenant
  alias CommsCore.ServiceAccounts.ServiceAccount
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

    service_user = Repo.get!(User, account.user_id)
    device = Repo.get!(Device, account.device_id)
    assert service_user.account_type == :service
    assert service_user.role == :member
    assert service_user.status == :active
    assert service_user.password_hash == nil
    assert service_user.email == "#{account.id}@service.invalid"
    assert device.platform == "service_account"

    assert {:error, :invalid_credentials} =
             Accounts.authenticate_view(owner.tenant.slug, service_user.email, "any-password")

    assert {:error, :not_found} =
             Accounts.change_user(
               service_user.id,
               %{status: "suspended", version: service_user.lock_version, reason: "generic path"},
               subject
             )

    assert {:error, :forbidden} =
             Administration.create_invitation(
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
    assert Repo.get!(User, account.user_id).status == :suspended
    refute is_nil(Repo.get!(Device, account.device_id).revoked_at)

    audit_text =
      Audit.list(%{tenant_id: owner.tenant.id, resource_id: account.id})
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

    assert {:ok, conversations} = Conversations.list_for_service(service_subject)
    assert Enum.any?(conversations, &(&1.id == owner.conversation.id))

    message_attrs = %{
      client_message_id: "service-idempotency-0001",
      body: "Release 42 is ready",
      metadata: %{"source" => "release-bot"},
      tenant_id: Ecto.UUID.generate(),
      conversation_id: Ecto.UUID.generate(),
      sender_user_id: Ecto.UUID.generate(),
      sender_device_id: Ecto.UUID.generate()
    }

    assert {:error, :invalid_attachments} =
             Messaging.accept_service_message_with_status(
               owner.conversation.id,
               Map.put(message_attrs, :attachment_ids, [Ecto.UUID.generate()]),
               service_subject
             )

    caller = self()
    tracer = spawn_link(fn -> forward_traces(caller) end)
    trace_target = {Conversations, :authorize_service_access, 3}
    :erlang.trace(caller, true, [:call, {:tracer, tracer}])
    :erlang.trace_pattern(trace_target, true, [:local])

    first =
      try do
        assert {:ok, first, :created} =
                 Messaging.accept_service_message_with_status(
                   owner.conversation.id,
                   message_attrs,
                   service_subject
                 )

        assert_receive {:trace, ^caller, :call,
                        {Conversations, :authorize_service_access,
                         [^service_subject, "messages:write", conversation_id]}},
                       1_000

        assert conversation_id == owner.conversation.id

        assert_receive {:trace, ^caller, :call,
                        {Conversations, :authorize_service_access,
                         [^service_subject, "messages:write", conversation_id]}},
                       1_000

        assert conversation_id == owner.conversation.id
        first
      after
        :erlang.trace(caller, false, [:call])
        :erlang.trace_pattern(trace_target, false, [:local])
        send(tracer, :stop)
      end

    assert first.tenant_id == owner.tenant.id
    assert first.conversation_id == owner.conversation.id
    assert first.sender_user_id == bot_id
    assert first.sender_device_id == created.service_account.device_id

    assert {:ok, replay, :duplicate} =
             Messaging.accept_service_message_with_status(
               owner.conversation.id,
               message_attrs,
               service_subject
             )

    assert replay.id == first.id

    assert {:ok, history} =
             Messaging.list_service_history(owner.conversation.id, service_subject, limit: 20)

    assert Enum.any?(history, &(&1.id == first.id))
    assert {:ok, search} = Messaging.search_for_service("Release 42", service_subject)
    assert Enum.any?(search, &(&1.id == first.id))

    assert {:ok, _archived} =
             Conversations.archive(
               owner.conversation.id,
               %{version: owner.conversation.lock_version},
               subject
             )

    assert {:error, :forbidden} =
             Messaging.list_service_history(owner.conversation.id, service_subject)

    assert {:error, :forbidden} =
             Messaging.accept_service_message_with_status(
               owner.conversation.id,
               message_attrs,
               service_subject
             )

    assert {:error, :forbidden} =
             Messaging.accept_service_message_with_status(
               owner.conversation.id,
               %{message_attrs | client_message_id: "service-after-archive-0001"},
               service_subject
             )

    assert {:ok, archived_search} =
             Messaging.search_for_service("Release 42", service_subject)

    refute Enum.any?(archived_search, &(&1.id == first.id))

    assert {:ok, private_conversation} =
             Conversations.create(
               %{kind: "group", title: "Humans only", visibility: "private", member_ids: []},
               subject
             )

    assert {:error, :forbidden} =
             Messaging.list_service_history(private_conversation.id, service_subject)

    assert {:error, :forbidden} =
             Messaging.accept_service_message_with_status(
               private_conversation.id,
               message_attrs,
               service_subject
             )

    other_tenant = Fixtures.account_fixture()

    assert {:error, :forbidden} =
             Messaging.list_service_history(other_tenant.conversation.id, service_subject)

    assert {:error, :forbidden} =
             Messaging.list_service_history("not-a-conversation-id", service_subject)
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
    assert {:ok, _} = Conversations.list_for_service(service_subject)

    assert {:error, :forbidden} =
             Messaging.list_service_history(owner.conversation.id, service_subject)

    assert {:error, :forbidden} =
             Messaging.accept_service_message_with_status(
               owner.conversation.id,
               %{client_message_id: "wrong-scope-0001", body: "blocked"},
               service_subject
             )

    assert {:error, :forbidden} = Messaging.search_for_service("blocked", service_subject)
    assert {:error, :forbidden} = Messaging.search_for_service("   ", service_subject)
  end

  test "service authorization rejects malformed identities and non-member service users" do
    malformed_subject = %{
      auth_type: :service,
      service_account_id: "bad",
      tenant_id: "bad",
      user_id: "bad",
      device_id: "bad",
      credential_generation: 1,
      scopes: ["conversations:read"]
    }

    assert {:error, :forbidden} =
             ServiceAccounts.authorize_service(malformed_subject, "conversations:read")

    owner = Fixtures.account_fixture()
    subject = Fixtures.step_up(owner)

    assert {:ok, created} =
             ServiceAccounts.create(
               %{
                 name: "Integrity Bot",
                 scopes: ["conversations:read"],
                 reason: "Exercise command-time identity integrity"
               },
               subject
             )

    assert {:ok, service_subject} = ServiceAccounts.authenticate(created.credential)
    assert :ok = ServiceAccounts.authorize_service(service_subject, "conversations:read")

    from(user in User, where: user.id == ^created.service_account.user_id)
    |> Repo.update_all(set: [role: :owner])

    assert {:error, :forbidden} =
             ServiceAccounts.authorize_service(service_subject, "conversations:read")
  end

  test "service authentication and authorization fail closed for an inactive tenant" do
    owner = Fixtures.account_fixture()
    subject = Fixtures.step_up(owner)

    assert {:ok, created} =
             ServiceAccounts.create(
               %{
                 name: "Tenant Status Bot",
                 scopes: ["conversations:read"],
                 reason: "Verify tenant owner status enforcement"
               },
               subject
             )

    assert {:ok, service_subject} = ServiceAccounts.authenticate(created.credential)
    assert :ok = ServiceAccounts.authorize_service(service_subject, "conversations:read")

    Tenant
    |> Repo.get!(owner.tenant.id)
    |> Tenant.changeset(%{status: :suspended})
    |> Repo.update!()

    assert {:error, :invalid_service_token} =
             ServiceAccounts.authenticate(created.credential)

    assert {:error, :forbidden} =
             ServiceAccounts.authorize_service(service_subject, "conversations:read")

    assert {:error, :forbidden} = ServiceAccounts.list(subject)
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
    assert Repo.get!(User, expired.user_id).status == :suspended
    refute is_nil(Repo.get!(Device, expired.device_id).revoked_at)
  end

  defp forward_traces(parent) do
    receive do
      :stop ->
        :ok

      message ->
        send(parent, message)
        forward_traces(parent)
    end
  end
end
