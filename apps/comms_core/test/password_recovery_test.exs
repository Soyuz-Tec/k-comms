defmodule CommsCore.PasswordRecoveryTest do
  use CommsCore.DataCase, async: false

  defmodule FailingCallLifecycleAdapter do
    @behaviour CommsCore.Accounts.CallLifecyclePort

    @impl true
    def revoke_identity_access(%CommsCore.Accounts.CallLifecycleCommand{} = command) do
      send(
        self(),
        {:call_lifecycle_contribution, CommsCore.Repo.in_transaction?(), command}
      )

      {:error, :forced_call_lifecycle_failure}
    end
  end

  alias CommsCore.Accounts.{Device, PasswordRecoveryRequest, Session, User}
  alias CommsCore.Accounts.PasswordRecovery, as: IdentityPasswordRecovery
  alias CommsCore.Administration.Tenant
  alias CommsCore.Notifications
  alias CommsCore.Notifications.{Intent, PushSubscription}
  alias CommsCore.{Accounts, Audit, PasswordRecovery, Repo}
  alias CommsCore.Security.Password
  alias CommsTestSupport.Fixtures

  @p256dh "BIdD6B2jZb5v7fwxbXdnpkOpJrsegpqJbZPPoWb3dI6m5jpkSTB_ZekUrAdKVXR4f_s5nU89TSZlDOxcTHJxAFo"
  @auth "AAECAwQFBgcICQoLDA0ODw"
  @dummy_tenant_id "00000000-0000-0000-0000-000000000000"

  test "known and unknown recovery requests are indistinguishable and sensitive intents stay hidden" do
    account = Fixtures.account_fixture()
    attrs = %{tenant_slug: account.tenant.slug, email: account.user.email}

    assert :ok = PasswordRecovery.request(attrs)

    assert :ok =
             PasswordRecovery.request(%{
               tenant_slug: "unknown-tenant",
               email: "unknown@example.test"
             })

    assert Repo.aggregate(PasswordRecoveryRequest, :count) == 1
    assert Repo.aggregate(Intent, :count) == 1

    recovery = Repo.one!(PasswordRecoveryRequest)
    intent = Repo.one!(Intent)

    assert intent.event_type == PasswordRecovery.event_type()
    assert intent.payload == %{"recovery_request_id" => recovery.id}
    refute Map.has_key?(intent.payload, "action_url")
    refute Map.has_key?(intent.payload, "token")

    assert {:ok, []} = Notifications.list_intents(Fixtures.subject(account))
    assert {:ok, []} = Notifications.list_attempts(Fixtures.subject(account))

    job = Repo.one!(Oban.Job)
    encoded_job = Jason.encode!(job.args)
    refute encoded_job =~ account.user.email
    refute encoded_job =~ "action_url"
    refute encoded_job =~ "token"

    audit =
      Audit.get_by!(%{
        tenant_id: account.tenant.id,
        action: "password_recovery.request"
      })

    encoded_audit = Jason.encode!(audit.metadata)
    refute encoded_audit =~ account.user.email
    refute encoded_audit =~ account.tenant.slug
    refute encoded_audit =~ "token"

    assert {:ok, delivery} = materialize_recovery(intent)
    assert delivery.destination == account.user.email
    assert delivery.payload["action_url"] =~ "/reset-password#token="
    refute delivery.payload["action_url"] =~ "?token="

    token = token_from_url(delivery.payload["action_url"])
    refute inspect(recovery) =~ token
    refute Jason.encode!(intent.payload) =~ token
    refute encoded_job =~ token
    refute encoded_audit =~ token
  end

  test "public recovery responses honor the configured minimum duration" do
    previous_minimum = Application.get_env(:comms_core, :password_recovery_min_response_ms)
    previous_jitter = Application.get_env(:comms_core, :password_recovery_jitter_ms)
    Application.put_env(:comms_core, :password_recovery_min_response_ms, 250)
    Application.put_env(:comms_core, :password_recovery_jitter_ms, 0)

    on_exit(fn ->
      Application.put_env(
        :comms_core,
        :password_recovery_min_response_ms,
        previous_minimum || 0
      )

      Application.put_env(:comms_core, :password_recovery_jitter_ms, previous_jitter || 0)
    end)

    started_at = System.monotonic_time(:millisecond)

    assert :ok =
             PasswordRecovery.request(%{
               tenant_slug: "timing-unknown",
               email: "unknown@example.test"
             })

    assert System.monotonic_time(:millisecond) - started_at >= 245
  end

  test "missing tenants still execute the identity lookup with the fixed dummy tenant id" do
    parent = self()
    handler_id = {__MODULE__, :missing_tenant_identity_lookup, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler_id,
               [:comms_core, :repo, :query],
               fn _event, _measurements, metadata, test_pid ->
                 query = Map.get(metadata, :query, "")

                 if String.contains?(query, ~s(FROM "users")) and
                      not String.contains?(query, "FOR UPDATE") do
                   send(
                     test_pid,
                     {:password_recovery_identity_lookup, query, Map.get(metadata, :params, [])}
                   )
                 end
               end,
               parent
             )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok =
             PasswordRecovery.request(%{
               tenant_slug: "missing-password-recovery-tenant",
               email: "missing-password-recovery-user@example.test"
             })

    assert_receive {:password_recovery_identity_lookup, query, params}
    refute query =~ ~s(JOIN "tenants")
    assert Ecto.UUID.dump!(@dummy_tenant_id) in params
  end

  test "new requests invalidate old tokens and reset consumes once, changes password, and revokes access" do
    account = Fixtures.account_fixture()
    old_password = fixture_password(account)

    assert {:ok, %{subscription: push_subscription}} =
             Notifications.register_push_subscription(
               push_subscription_attrs(),
               Fixtures.subject(account)
             )

    assert {:ok, second_login} =
             Accounts.authenticate(account.tenant.slug, account.user.email, old_password, %{
               name: "Recovery test browser",
               platform: "test"
             })

    attrs = %{tenant_slug: account.tenant.slug, email: account.user.email}
    assert :ok = PasswordRecovery.request(attrs)
    first = latest_recovery()
    first_token = token_for_recovery(first)

    assert :ok = PasswordRecovery.request(attrs)
    second = latest_recovery()
    second_token = token_for_recovery(second)

    refute first.id == second.id
    assert Repo.get!(PasswordRecoveryRequest, first.id).invalidated_at

    assert {:error, :invalid_password_recovery_token} =
             PasswordRecovery.reset(%{
               token: first_token,
               new_password: "correct-horse-recovered-password"
             })

    assert {:error, :weak_password} =
             PasswordRecovery.reset(%{token: second_token, new_password: "too-short"})

    assert {:ok, result} =
             PasswordRecovery.reset(%{
               token: second_token,
               new_password: "correct-horse-recovered-password"
             })

    assert account.session.id in result.revoked_session_ids
    assert second_login.session.id in result.revoked_session_ids
    assert Repo.get!(PasswordRecoveryRequest, second.id).consumed_at

    user = Repo.get!(User, account.user.id)
    assert Password.verify("correct-horse-recovered-password", user.password_hash)
    refute Password.verify(old_password, user.password_hash)

    assert Repo.aggregate(
             from(session in Session,
               where: session.user_id == ^account.user.id and is_nil(session.revoked_at)
             ),
             :count
           ) == 0

    assert Repo.aggregate(
             from(device in Device,
               where: device.user_id == ^account.user.id and is_nil(device.revoked_at)
             ),
             :count
           ) == 0

    assert Repo.get!(PushSubscription, push_subscription.id).status == :revoked

    assert {:error, :invalid_password_recovery_token} =
             PasswordRecovery.reset(%{
               token: second_token,
               new_password: "another-correct-horse-password"
             })

    consume_audit =
      Audit.get_by!(%{
        tenant_id: account.tenant.id,
        action: "password_recovery.consume"
      })

    refute Jason.encode!(consume_audit.metadata) =~ second_token
    refute Jason.encode!(consume_audit.metadata) =~ account.user.email
  end

  test "call revocation is contributed inside reset transaction and failure rolls everything back" do
    account = Fixtures.account_fixture()
    old_user = Repo.get!(User, account.user.id)

    assert :ok =
             PasswordRecovery.request(%{
               tenant_slug: account.tenant.slug,
               email: account.user.email
             })

    recovery = latest_recovery()
    token = token_for_recovery(recovery)
    tenant_id = account.tenant.id
    user_id = account.user.id

    previous_adapter =
      Application.fetch_env(:comms_core, :identity_call_lifecycle_adapter)

    Application.put_env(
      :comms_core,
      :identity_call_lifecycle_adapter,
      FailingCallLifecycleAdapter
    )

    on_exit(fn ->
      case previous_adapter do
        {:ok, adapter} ->
          Application.put_env(:comms_core, :identity_call_lifecycle_adapter, adapter)

        :error ->
          Application.delete_env(:comms_core, :identity_call_lifecycle_adapter)
      end
    end)

    assert {:error, :forced_call_lifecycle_failure} =
             IdentityPasswordRecovery.reset(%{
               token: token,
               new_password: "correct-horse-call-rollback"
             })

    assert_receive {:call_lifecycle_contribution, true,
                    %CommsCore.Accounts.CallLifecycleCommand{
                      operation: :user_access_revoked,
                      tenant_id: ^tenant_id,
                      user_id: ^user_id,
                      reason: "password_recovery"
                    }}

    assert is_nil(Repo.get!(PasswordRecoveryRequest, recovery.id).consumed_at)
    assert Repo.get!(User, account.user.id).password_hash == old_user.password_hash
    assert is_nil(Repo.get!(Session, account.session.id).revoked_at)
    assert is_nil(Repo.get!(Device, account.device.id).revoked_at)
  end

  test "tenant suspension prevents recovery creation, delivery, and reset consumption" do
    account = Fixtures.account_fixture()

    assert :ok =
             PasswordRecovery.request(%{
               tenant_slug: account.tenant.slug,
               email: account.user.email
             })

    recovery = latest_recovery()
    token = token_for_recovery(recovery)
    old_password_hash = Repo.get!(User, account.user.id).password_hash
    intent_count = Repo.aggregate(Intent, :count)

    account.tenant
    |> Tenant.changeset(%{status: :suspended})
    |> Repo.update!()

    assert {:error, :password_recovery_not_deliverable} =
             PasswordRecovery.materialize_notification(%{
               tenant_id: account.tenant.id,
               user_id: account.user.id,
               recovery_request_id: recovery.id
             })

    assert {:error, :invalid_password_recovery_token} =
             PasswordRecovery.reset(%{
               token: token,
               new_password: "correct-horse-suspended-tenant"
             })

    assert :ok =
             PasswordRecovery.request(%{
               tenant_slug: account.tenant.slug,
               email: account.user.email
             })

    assert Repo.aggregate(Intent, :count) == intent_count
    assert is_nil(Repo.get!(PasswordRecoveryRequest, recovery.id).consumed_at)
    assert Repo.get!(User, account.user.id).password_hash == old_password_hash
    assert is_nil(Repo.get!(Session, account.session.id).revoked_at)
    assert is_nil(Repo.get!(Device, account.device.id).revoked_at)
  end

  test "expired recovery tokens cannot materialize or reset" do
    account = Fixtures.account_fixture()

    assert :ok =
             PasswordRecovery.request(%{
               tenant_slug: account.tenant.slug,
               email: account.user.email
             })

    recovery = latest_recovery()
    token = token_for_recovery(recovery)
    expired_at = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:microsecond)

    recovery
    |> PasswordRecoveryRequest.changeset(%{expires_at: expired_at})
    |> Repo.update!()

    intent = Repo.get_by!(Intent, event_type: PasswordRecovery.event_type())

    assert {:error, :password_recovery_not_deliverable} =
             materialize_recovery(intent)

    assert {:error, :invalid_password_recovery_token} =
             PasswordRecovery.reset(%{
               token: token,
               new_password: "correct-horse-expired-token"
             })
  end

  test "concurrent request and reset paths serialize per user with one deliverable token" do
    account = Fixtures.account_fixture()
    attrs = %{tenant_slug: account.tenant.slug, email: account.user.email}

    request_results =
      1..6
      |> Task.async_stream(fn _ -> PasswordRecovery.request(attrs) end,
        max_concurrency: 6,
        timeout: 30_000,
        ordered: false
      )
      |> Enum.to_list()

    assert Enum.all?(request_results, &match?({:ok, :ok}, &1))
    assert outstanding_request_count(account.user.id) == 1
    assert deliverable_intent_count(account.user.id) == 1

    current = latest_recovery()
    token = token_for_recovery(current)

    reset_task =
      Task.async(fn ->
        PasswordRecovery.reset(%{
          token: token,
          new_password: "correct-horse-concurrent-recovery"
        })
      end)

    request_task = Task.async(fn -> PasswordRecovery.request(attrs) end)

    reset_result = Task.await(reset_task, 30_000)
    assert :ok = Task.await(request_task, 30_000)

    assert match?({:ok, _}, reset_result) or
             reset_result == {:error, :invalid_password_recovery_token}

    assert outstanding_request_count(account.user.id) == 1
    assert deliverable_intent_count(account.user.id) == 1
  end

  test "opportunistic cleanup is bounded to stale recovery rows and preserves audit evidence" do
    account = Fixtures.account_fixture()
    attrs = %{tenant_slug: account.tenant.slug, email: account.user.email}
    assert :ok = PasswordRecovery.request(attrs)

    stale = latest_recovery()
    stale_at = DateTime.add(DateTime.utc_now(), -2_678_400, :second)

    stale
    |> PasswordRecoveryRequest.changeset(%{
      expires_at: stale_at,
      consumed_at: stale_at
    })
    |> Repo.update!()

    assert Audit.get_by!(%{
             tenant_id: account.tenant.id,
             action: "password_recovery.request",
             resource_id: stale.id
           })

    assert :ok = PasswordRecovery.request(attrs)
    refute Repo.get(PasswordRecoveryRequest, stale.id)
    assert outstanding_request_count(account.user.id) == 1

    assert Audit.get_by!(%{
             tenant_id: account.tenant.id,
             action: "password_recovery.request",
             resource_id: stale.id
           })
  end

  defp latest_recovery do
    PasswordRecoveryRequest
    |> order_by([request], desc: request.inserted_at)
    |> limit(1)
    |> Repo.one!()
  end

  defp token_for_recovery(recovery) do
    intent =
      Intent
      |> where(
        [intent],
        intent.event_type == ^PasswordRecovery.event_type() and
          intent.user_id == ^recovery.user_id
      )
      |> Repo.all()
      |> Enum.find(&(&1.payload["recovery_request_id"] == recovery.id))

    {:ok, delivery} = materialize_recovery(intent)
    token_from_url(delivery.payload["action_url"])
  end

  defp token_from_url(url) do
    fragment = URI.parse(url).fragment
    fragment |> URI.decode_query() |> Map.fetch!("token")
  end

  defp outstanding_request_count(user_id) do
    Repo.aggregate(
      from(request in PasswordRecoveryRequest,
        where:
          request.user_id == ^user_id and is_nil(request.consumed_at) and
            is_nil(request.invalidated_at) and request.expires_at > ^DateTime.utc_now()
      ),
      :count
    )
  end

  defp deliverable_intent_count(user_id) do
    Intent
    |> where(
      [intent],
      intent.event_type == ^PasswordRecovery.event_type() and intent.user_id == ^user_id
    )
    |> Repo.all()
    |> Enum.count(&match?({:ok, _}, materialize_recovery(&1)))
  end

  defp materialize_recovery(intent) do
    PasswordRecovery.materialize_notification(%{
      tenant_id: intent.tenant_id,
      user_id: intent.user_id,
      recovery_request_id: intent.payload["recovery_request_id"]
    })
  end

  defp fixture_password(account) do
    suffix = account.tenant.slug |> String.split("-") |> List.last()
    "correct-horse-battery-#{suffix}"
  end

  defp push_subscription_attrs do
    %{
      endpoint: "https://push.example.test/send/password-recovery-reset",
      expiration_time: nil,
      keys: %{p256dh: @p256dh, auth: @auth}
    }
  end
end
