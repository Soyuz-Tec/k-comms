defmodule CommsCore.Notifications.PushSubscriptionsTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts.Device

  alias CommsCore.Notifications.{
    Intent,
    PushSubscription,
    PushSubscriptions,
    PushSubscriptionView
  }

  alias CommsCore.{Accounts, Audit, Governance, Notifications, Repo}
  alias CommsCore.Security.PushSubscriptionBox
  alias CommsTestSupport.Fixtures

  @p256dh "BIdD6B2jZb5v7fwxbXdnpkOpJrsegpqJbZPPoWb3dI6m5jpkSTB_ZekUrAdKVXR4f_s5nU89TSZlDOxcTHJxAFo"
  @auth "AAECAwQFBgcICQoLDA0ODw"

  test "registers a per-device subscription without persisting or presenting capability material" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    attrs = subscription_attrs("https://push.example.test/send/secret-capability?token=private")

    assert {:ok, %{subscription: subscription, replayed: false}} =
             Notifications.register_push_subscription(attrs, subject)

    assert %PushSubscriptionView{} = subscription
    refute Map.has_key?(Map.from_struct(subscription), :ciphertext)
    refute Map.has_key?(Map.from_struct(subscription), :endpoint_hash)

    assert {:ok, [%PushSubscriptionView{id: id}]} =
             Notifications.list_push_subscriptions(subject)

    assert id == subscription.id

    stored = Repo.get!(PushSubscription, subscription.id)
    assert stored.endpoint_hint == "push.example.test"
    assert byte_size(stored.endpoint_hash) == 32
    refute :binary.match(stored.ciphertext, "secret-capability") != :nomatch
    refute inspect(stored) =~ "secret-capability"
    refute inspect(stored) =~ @p256dh
    refute inspect(stored) =~ @auth

    assert {:error, :push_subscription_decryption_failed} =
             PushSubscriptionBox.decrypt(
               %{
                 ciphertext: stored.ciphertext,
                 nonce: stored.nonce,
                 tag: stored.tag,
                 key_id: stored.key_id
               },
               %{
                 tenant_id: Ecto.UUID.generate(),
                 subscription_id: stored.id,
                 version: stored.version
               }
             )

    assert {:ok, destination} =
             PushSubscriptions.materialize_destination(
               stored.id,
               stored.version,
               stored.tenant_id
             )

    assert destination == %{
             "endpoint" => attrs.endpoint,
             "expirationTime" => nil,
             "keys" => %{"auth" => @auth, "p256dh" => @p256dh},
             "version" => 1
           }

    event =
      Audit.get_by!(%{
        tenant_id: account.tenant.id,
        resource_type: "push_subscription",
        resource_id: stored.id
      })

    refute inspect(event.metadata) =~ "secret-capability"
    refute inspect(event.metadata) =~ "token=private"
  end

  test "duplicate registration is idempotent and key rotation advances the generation" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    attrs = subscription_attrs("https://push.example.test/send/idempotent")

    assert {:ok, %{subscription: first, replayed: false}} =
             PushSubscriptions.register(attrs, subject)

    assert {:ok, %{subscription: replay, replayed: true}} =
             PushSubscriptions.register(attrs, subject)

    assert replay.id == first.id
    assert replay.version == first.version
    assert Repo.aggregate(PushSubscription, :count) == 1

    rotated_attrs =
      put_in(
        attrs,
        [:keys, :auth],
        Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      )

    assert {:ok, %{subscription: rotated, replayed: false}} =
             PushSubscriptions.register(rotated_attrs, subject)

    assert rotated.id == first.id
    assert rotated.version == first.version + 1

    assert {:error, :push_subscription_stale} =
             PushSubscriptions.materialize_destination(first.id, first.version, first.tenant_id)

    assert {:ok, _} =
             PushSubscriptions.materialize_destination(
               rotated.id,
               rotated.version,
               rotated.tenant_id
             )
  end

  test "concurrent registration cannot over-admit device or user subscription capacity" do
    device_account = Fixtures.account_fixture()
    device_subject = Fixtures.subject(device_account)

    device_results =
      1..12
      |> Task.async_stream(
        fn index ->
          PushSubscriptions.register(
            subscription_attrs("https://push.example.test/send/device-cap-#{index}"),
            device_subject
          )
        end,
        max_concurrency: 12,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(device_results, &match?({:ok, _}, &1)) == 5

    assert Enum.count(
             device_results,
             &match?({:error, :push_subscription_limit_reached}, &1)
           ) == 7

    assert Repo.aggregate(PushSubscription, :count) == 5

    user_account = Fixtures.account_fixture()

    additional_logins =
      Enum.map(1..2, fn index ->
        suffix = user_account.tenant.slug |> String.split("-") |> List.last()

        {:ok, login} =
          Accounts.authenticate(
            user_account.tenant.slug,
            user_account.user.email,
            "correct-horse-battery-#{suffix}",
            %{name: "Capacity browser #{index}", platform: "test"}
          )

        login
      end)

    subjects = [
      Fixtures.subject(user_account)
      | Enum.map(additional_logins, &Accounts.subject_for_session(&1.session))
    ]

    user_results =
      1..18
      |> Task.async_stream(
        fn index ->
          subject = Enum.at(subjects, rem(index - 1, length(subjects)))

          PushSubscriptions.register(
            subscription_attrs("https://push.example.test/send/user-cap-#{index}"),
            subject
          )
        end,
        max_concurrency: 18,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(user_results, &match?({:ok, _}, &1)) == 10

    assert Enum.count(
             user_results,
             &match?({:error, :push_subscription_limit_reached}, &1)
           ) == 8

    assert length(
             PushSubscriptions.active_subscription_ids(
               user_account.tenant.id,
               user_account.user.id
             )
           ) == 10

    counts_by_device =
      PushSubscription
      |> where(
        [subscription],
        subscription.tenant_id == ^user_account.tenant.id and
          subscription.user_id == ^user_account.user.id and subscription.status == :active
      )
      |> group_by([subscription], subscription.device_id)
      |> select([subscription], {subscription.device_id, count(subscription.id)})
      |> Repo.all()

    assert Enum.all?(counts_by_device, fn {_device_id, count} -> count <= 5 end)
  end

  test "deleting a subscription preserves the historical delivery generation" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, %{subscription: subscription}} =
             PushSubscriptions.register(
               subscription_attrs("https://push.example.test/send/history"),
               subject
             )

    intent =
      %Intent{}
      |> Intent.changeset(%{
        tenant_id: account.tenant.id,
        user_id: account.user.id,
        event_type: "message.created.v1",
        channel: :push,
        destination: subscription.id,
        push_subscription_id: subscription.id,
        push_subscription_version: subscription.version,
        payload: %{},
        idempotency_key: "push-history-#{subscription.id}",
        status: :pending,
        next_attempt_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    Repo.delete!(subscription)

    orphaned = Repo.get!(Intent, intent.id)
    assert is_nil(orphaned.push_subscription_id)
    assert orphaned.push_subscription_version == subscription.version
  end

  test "validates HTTPS endpoints, p256dh, auth, and expiration bounds" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:error, :invalid_push_endpoint} =
             PushSubscriptions.register(
               subscription_attrs("http://push.example.test/send/x"),
               subject
             )

    assert {:error, :invalid_push_endpoint} =
             PushSubscriptions.register(
               subscription_attrs("https://user:pass@push.example.test/send/x"),
               subject
             )

    assert {:error, :invalid_push_p256dh_key} =
             PushSubscriptions.register(
               put_in(subscription_attrs(), [:keys, :p256dh], "not-a-p256-key"),
               subject
             )

    assert {:error, :invalid_push_auth_key} =
             PushSubscriptions.register(
               put_in(
                 subscription_attrs(),
                 [:keys, :auth],
                 Base.url_encode64(<<1, 2>>, padding: false)
               ),
               subject
             )

    assert {:error, :invalid_push_expiration} =
             PushSubscriptions.register(
               Map.put(
                 subscription_attrs(),
                 :expiration_time,
                 System.system_time(:millisecond) - 1_000
               ),
               subject
             )
  end

  test "device/user ownership is enforced by both API scope and the database composite FK" do
    owner = Fixtures.account_fixture()
    member = Fixtures.user_fixture(owner).user

    {:ok, member_device} =
      %Device{}
      |> Device.changeset(%{
        tenant_id: owner.tenant.id,
        user_id: member.id,
        name: "Member browser",
        platform: "test"
      })
      |> Repo.insert()

    subject = Fixtures.subject(owner)

    assert {:ok, %{subscription: subscription}} =
             PushSubscriptions.register(subscription_attrs(), subject)

    invalid =
      %PushSubscription{id: Ecto.UUID.generate()}
      |> PushSubscription.changeset(%{
        tenant_id: owner.tenant.id,
        user_id: owner.user.id,
        device_id: member_device.id,
        endpoint_hash: :crypto.hash(:sha256, "https://push.example.test/send/mismatch"),
        endpoint_hint: "push.example.test",
        version: 1,
        ciphertext: subscription.ciphertext,
        nonce: subscription.nonce,
        tag: subscription.tag,
        key_id: subscription.key_id,
        status: :active
      })

    assert {:error, changeset} = Repo.insert(invalid)
    assert {"does not exist", _} = changeset.errors[:device_id]

    other = Fixtures.account_fixture()

    assert {:error, :push_subscription_conflict} =
             PushSubscriptions.register(subscription_attrs(), Fixtures.subject(other))

    assert {:error, :not_found} =
             PushSubscriptions.revoke(subscription.id, Fixtures.subject(other))
  end

  test "revocation and direct device revocation fail closed during materialization" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, %{subscription: subscription}} =
             PushSubscriptions.register(subscription_attrs(), subject)

    assert :ok =
             PushSubscriptions.disable_for_device(
               account.tenant.id,
               account.user.id,
               account.device.id
             )

    assert {:error, :push_subscription_revoked} =
             PushSubscriptions.materialize_destination(
               subscription.id,
               subscription.version,
               subscription.tenant_id
             )

    second_endpoint = subscription_attrs("https://push.example.test/send/revoked-device")
    assert {:ok, %{subscription: second}} = PushSubscriptions.register(second_endpoint, subject)

    account.device
    |> Device.changeset(%{revoked_at: DateTime.utc_now()})
    |> Repo.update!()

    assert [] == PushSubscriptions.active_subscription_ids(account.tenant.id, account.user.id)

    assert {:error, :push_subscription_stale} =
             PushSubscriptions.materialize_destination(
               second.id,
               second.version,
               second.tenant_id
             )
  end

  test "an explicit same-device registration reactivates a revoked endpoint as a new generation" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    attrs = subscription_attrs("https://push.example.test/send/reactivate")

    assert {:ok, %{subscription: original}} = PushSubscriptions.register(attrs, subject)
    assert {:ok, revoked} = PushSubscriptions.revoke(original.id, subject)
    assert revoked.status == :revoked

    assert {:ok, %{subscription: active, replayed: false}} =
             PushSubscriptions.register(attrs, subject)

    assert active.id == original.id
    assert active.version == original.version + 1
    assert active.status == :active
    assert is_nil(active.revoked_at)
    assert is_nil(active.stale_at)
    assert is_nil(active.disabled_reason)

    assert {:error, :push_subscription_stale} =
             PushSubscriptions.materialize_destination(
               original.id,
               original.version,
               original.tenant_id
             )

    assert {:ok, _} =
             PushSubscriptions.materialize_destination(
               active.id,
               active.version,
               active.tenant_id
             )
  end

  test "the account device-revocation transaction disables its push subscriptions" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, %{subscription: subscription}} =
             PushSubscriptions.register(subscription_attrs(), subject)

    assert {:ok, _result} = Accounts.revoke_device(account.device.id, subject)
    assert Repo.get!(PushSubscription, subscription.id).status == :revoked
    assert {:error, :forbidden} = PushSubscriptions.list(subject)
  end

  test "the governed user-lifecycle transaction disables the user's push subscriptions" do
    account = Fixtures.account_fixture()
    owner_subject = Fixtures.step_up(account)
    password = "correct-horse-lifecycle-member"

    assert {:ok, member} =
             Accounts.create_user(
               %{
                 display_name: "Lifecycle member",
                 email: "lifecycle-member@example.test",
                 password: password,
                 role: "member"
               },
               owner_subject
             )

    assert {:ok, login} =
             Accounts.authenticate(
               account.tenant.slug,
               member.email,
               password,
               %{name: "Lifecycle member browser", platform: "test"}
             )

    member_subject = Accounts.subject_for_session(login.session)

    assert {:ok, %{subscription: subscription}} =
             PushSubscriptions.register(
               subscription_attrs("https://push.example.test/send/lifecycle-member"),
               member_subject
             )

    assert {:ok, %{user: suspended}} =
             Governance.change_user_lifecycle_view(
               member.id,
               %{
                 version: member.lock_version,
                 status: "suspended",
                 reason: "disable lifecycle member access"
               },
               owner_subject
             )

    assert suspended.status == :suspended
    assert Repo.get!(PushSubscription, subscription.id).status == :revoked
  end

  test "late provider results cannot stale a newer encrypted generation" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    attrs = subscription_attrs()

    assert {:ok, %{subscription: original}} = PushSubscriptions.register(attrs, subject)

    rotated_auth = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    assert {:ok, %{subscription: rotated}} =
             PushSubscriptions.register(put_in(attrs, [:keys, :auth], rotated_auth), subject)

    assert :ok =
             PushSubscriptions.record_provider_result(
               original.id,
               original.version,
               {:error, :permanent, {:notification_status, 410}}
             )

    assert Repo.get!(PushSubscription, rotated.id).status == :active

    assert :ok =
             PushSubscriptions.record_provider_result(
               rotated.id,
               rotated.version,
               {:error, :permanent, {:notification_status, 410}}
             )

    assert Repo.get!(PushSubscription, rotated.id).status == :stale
  end

  test "old encrypted generations remain readable only while their key is retained" do
    previous_key = Application.get_env(:comms_core, :push_subscription_encryption_key)
    previous_keys = Application.get_env(:comms_core, :push_subscription_encryption_keys)
    previous_id = Application.get_env(:comms_core, :push_subscription_encryption_key_id)

    on_exit(fn ->
      restore(:push_subscription_encryption_key, previous_key)
      restore(:push_subscription_encryption_keys, previous_keys)
      restore(:push_subscription_encryption_key_id, previous_id)
    end)

    old_key = "0123456789abcdef0123456789abcdef"
    new_key = "abcdef0123456789abcdef0123456789"
    Application.delete_env(:comms_core, :push_subscription_encryption_key)
    Application.put_env(:comms_core, :push_subscription_encryption_keys, %{"old" => old_key})
    Application.put_env(:comms_core, :push_subscription_encryption_key_id, "old")

    account = Fixtures.account_fixture()

    assert {:ok, %{subscription: subscription}} =
             PushSubscriptions.register(subscription_attrs(), Fixtures.subject(account))

    Application.put_env(:comms_core, :push_subscription_encryption_keys, %{
      "old" => old_key,
      "new" => new_key
    })

    Application.put_env(:comms_core, :push_subscription_encryption_key_id, "new")

    assert {:ok, _} =
             PushSubscriptions.materialize_destination(
               subscription.id,
               subscription.version,
               subscription.tenant_id
             )

    Application.put_env(:comms_core, :push_subscription_encryption_keys, %{"new" => new_key})

    assert {:error, :push_subscription_encryption_key_unavailable} =
             PushSubscriptions.materialize_destination(
               subscription.id,
               subscription.version,
               subscription.tenant_id
             )
  end

  test "configuration fails closed without both the dedicated key and VAPID public key" do
    previous_vapid = Application.get_env(:comms_core, :web_push_vapid_public_key)
    previous_key = Application.get_env(:comms_core, :push_subscription_encryption_key)
    previous_keys = Application.get_env(:comms_core, :push_subscription_encryption_keys)

    on_exit(fn ->
      restore(:web_push_vapid_public_key, previous_vapid)
      restore(:push_subscription_encryption_key, previous_key)
      restore(:push_subscription_encryption_keys, previous_keys)
    end)

    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    Application.delete_env(:comms_core, :web_push_vapid_public_key)

    assert %{status: :unavailable, reason: :invalid_web_push_vapid_public_key} =
             PushSubscriptions.status()

    assert {:ok, %{available: false, vapid_public_key: nil}} = PushSubscriptions.config(subject)

    Application.put_env(:comms_core, :web_push_vapid_public_key, @p256dh)
    Application.delete_env(:comms_core, :push_subscription_encryption_key)
    Application.delete_env(:comms_core, :push_subscription_encryption_keys)

    assert %{status: :unavailable, reason: :current_push_subscription_key_not_configured} =
             PushSubscriptions.status()

    assert {:error, :current_push_subscription_key_not_configured} =
             PushSubscriptions.register(subscription_attrs(), subject)
  end

  test "configuration and registration require a real or explicit development delivery adapter" do
    previous_delivery = Application.get_env(:comms_core, :push_delivery_status)

    on_exit(fn ->
      restore(:push_delivery_status, previous_delivery)
    end)

    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    Application.put_env(:comms_core, :push_delivery_status, :unavailable)

    assert %{
             status: :unavailable,
             reason: :notification_delivery_unavailable,
             delivery: %{status: :unavailable}
           } = PushSubscriptions.status()

    assert {:ok, %{available: false, vapid_public_key: nil}} = PushSubscriptions.config(subject)

    assert {:error, :notification_delivery_unavailable} =
             PushSubscriptions.register(subscription_attrs(), subject)

    Application.put_env(:comms_core, :push_delivery_status, :degraded)

    assert %{status: :available, delivery: %{status: :degraded}} = PushSubscriptions.status()

    assert {:ok, %{available: true, vapid_public_key: @p256dh}} =
             PushSubscriptions.config(subject)
  end

  defp subscription_attrs(endpoint \\ "https://push.example.test/send/default") do
    %{
      endpoint: endpoint,
      expiration_time: nil,
      keys: %{p256dh: @p256dh, auth: @auth}
    }
  end

  defp restore(key, nil), do: Application.delete_env(:comms_core, key)
  defp restore(key, value), do: Application.put_env(:comms_core, key, value)
end
