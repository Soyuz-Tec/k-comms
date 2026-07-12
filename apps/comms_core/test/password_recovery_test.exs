defmodule CommsCore.PasswordRecoveryTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts.{Device, PasswordRecoveryRequest, Session, User}
  alias CommsCore.Audit.AuditEvent
  alias CommsCore.Notifications
  alias CommsCore.Notifications.Intent
  alias CommsCore.{Accounts, PasswordRecovery, Repo}
  alias CommsCore.Security.Password
  alias CommsTestSupport.Fixtures

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

    audit = Repo.get_by!(AuditEvent, action: "password_recovery.request")
    encoded_audit = Jason.encode!(audit.metadata)
    refute encoded_audit =~ account.user.email
    refute encoded_audit =~ account.tenant.slug
    refute encoded_audit =~ "token"

    assert {:ok, delivery} = PasswordRecovery.materialize_notification(intent)
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

  test "new requests invalidate old tokens and reset consumes once, changes password, and revokes access" do
    account = Fixtures.account_fixture()
    old_password = fixture_password(account)

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

    assert {:error, :invalid_password_recovery_token} =
             PasswordRecovery.reset(%{
               token: second_token,
               new_password: "another-correct-horse-password"
             })

    consume_audit = Repo.get_by!(AuditEvent, action: "password_recovery.consume")
    refute Jason.encode!(consume_audit.metadata) =~ second_token
    refute Jason.encode!(consume_audit.metadata) =~ account.user.email
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
             PasswordRecovery.materialize_notification(intent)

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

    assert Repo.get_by!(AuditEvent,
             action: "password_recovery.request",
             resource_id: stale.id
           )

    assert :ok = PasswordRecovery.request(attrs)
    refute Repo.get(PasswordRecoveryRequest, stale.id)
    assert outstanding_request_count(account.user.id) == 1

    assert Repo.get_by!(AuditEvent,
             action: "password_recovery.request",
             resource_id: stale.id
           )
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

    {:ok, delivery} = PasswordRecovery.materialize_notification(intent)
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
    |> Enum.count(&match?({:ok, _}, PasswordRecovery.materialize_notification(&1)))
  end

  defp fixture_password(account) do
    suffix = account.tenant.slug |> String.split("-") |> List.last()
    "correct-horse-battery-#{suffix}"
  end
end
