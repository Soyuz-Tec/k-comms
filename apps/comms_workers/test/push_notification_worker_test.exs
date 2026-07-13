defmodule CommsWorkers.PushNotificationWorkerTest.CaptureNotifications do
  @behaviour CommsIntegrations.Notifications

  @impl true
  def deliver(payload) do
    send(Application.fetch_env!(:comms_workers, :push_test_pid), {:push_delivery, payload})

    Application.get_env(
      :comms_workers,
      :push_test_result,
      {:ok, %{provider: "capture", provider_message_id: "push-test"}}
    )
  end

  @impl true
  def status, do: %{status: :available, adapter: "capture"}
end

defmodule CommsWorkers.PushNotificationWorkerTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Notifications.Intent
  alias CommsCore.Notifications.PushSubscription
  alias CommsCore.{Conversations, Notifications, PushSubscriptions, Repo}
  alias CommsTestSupport.Fixtures

  @p256dh "BIdD6B2jZb5v7fwxbXdnpkOpJrsegpqJbZPPoWb3dI6m5jpkSTB_ZekUrAdKVXR4f_s5nU89TSZlDOxcTHJxAFo"
  @auth "AAECAwQFBgcICQoLDA0ODw"
  @endpoint "https://push.example.test/send/worker-secret?capability=private"

  setup do
    previous_adapter = Application.get_env(:comms_integrations, :notification_adapter)
    previous_pid = Application.get_env(:comms_workers, :push_test_pid)
    previous_result = Application.get_env(:comms_workers, :push_test_result)

    Application.put_env(
      :comms_integrations,
      :notification_adapter,
      CommsWorkers.PushNotificationWorkerTest.CaptureNotifications
    )

    Application.put_env(:comms_workers, :push_test_pid, self())
    Application.delete_env(:comms_workers, :push_test_result)

    on_exit(fn ->
      restore(:comms_integrations, :notification_adapter, previous_adapter)
      restore(:comms_workers, :push_test_pid, previous_pid)
      restore(:comms_workers, :push_test_result, previous_result)
    end)

    :ok
  end

  test "only the worker materializes the exact encrypted browser subscription for the provider" do
    fixture = notification_fixture()

    assert fixture.intent.destination == fixture.subscription.id
    assert fixture.intent.push_subscription_id == fixture.subscription.id
    assert fixture.intent.push_subscription_version == fixture.subscription.version
    persisted_intent_text = inspect(fixture.intent, limit: :infinity)
    refute persisted_intent_text =~ @endpoint
    refute persisted_intent_text =~ @p256dh
    refute persisted_intent_text =~ @auth

    [job] =
      Repo.all(
        from(job in Oban.Job,
          where:
            job.worker == "CommsWorkers.NotificationWorker" and
              fragment("?->>'intent_id' = ?", job.args, ^fixture.intent.id)
        )
      )

    refute Jason.encode!(job.args) =~ @endpoint
    refute Jason.encode!(job.args) =~ @p256dh
    refute Jason.encode!(job.args) =~ @auth

    assert :ok = perform(fixture.intent)

    assert_receive {:push_delivery, delivered}
    assert delivered.channel == :push

    assert delivered.destination == %{
             "endpoint" => @endpoint,
             "expirationTime" => nil,
             "keys" => %{"auth" => @auth, "p256dh" => @p256dh},
             "version" => 1
           }

    persisted = Repo.get!(Intent, fixture.intent.id)
    assert persisted.status == :delivered
    refute inspect(persisted, limit: :infinity) =~ @endpoint
  end

  test "provider outage is retryable and a later retry uses just-in-time materialization" do
    fixture = notification_fixture("outage")

    Application.put_env(
      :comms_workers,
      :push_test_result,
      {:error, :notification_provider_unavailable}
    )

    assert {:error, :notification_provider_unavailable} = perform(fixture.intent)
    assert_receive {:push_delivery, _}
    assert Repo.get!(Intent, fixture.intent.id).status == :retryable

    stepped_up_owner = Fixtures.step_up(fixture.owner, fixture.owner_subject)
    assert {:ok, retried} = Notifications.retry_intent(fixture.intent.id, stepped_up_owner)
    Application.delete_env(:comms_workers, :push_test_result)

    assert :ok = perform(retried)
    assert_receive {:push_delivery, %{destination: %{"endpoint" => endpoint}}}
    assert endpoint == fixture.endpoint
    assert Repo.get!(Intent, fixture.intent.id).status == :delivered
  end

  test "TLS provider failures remain retryable" do
    fixture = notification_fixture("tls-retry")
    Application.put_env(:comms_workers, :push_test_result, {:error, :outbound_tls_error})

    assert {:error, :outbound_tls_error} = perform(fixture.intent)
    assert_receive {:push_delivery, _}
    assert Repo.get!(Intent, fixture.intent.id).status == :retryable
  end

  test "revoked subscriptions fail terminally before provider invocation" do
    fixture = notification_fixture("revoked")
    assert {:ok, _} = PushSubscriptions.revoke(fixture.subscription.id, fixture.recipient_subject)

    assert {:discard, :push_subscription_revoked} = perform(fixture.intent)
    refute_receive {:push_delivery, _}
    assert Repo.get!(Intent, fixture.intent.id).status == :failed
  end

  test "a current 410 stales the subscription but a prior generation cannot stale its rotation" do
    fixture = notification_fixture("gone")
    rotated_auth = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    assert {:ok, %{subscription: rotated}} =
             PushSubscriptions.register(
               subscription_attrs(fixture.endpoint, rotated_auth),
               fixture.recipient_subject
             )

    Application.put_env(
      :comms_workers,
      :push_test_result,
      {:error, :permanent, {:notification_status, 410}}
    )

    assert {:discard, :push_subscription_stale} = perform(fixture.intent)
    refute_receive {:push_delivery, _}
    assert Repo.get!(PushSubscription, rotated.id).status == :active

    newer_event = duplicate_event(fixture.event)
    assert :ok = Notifications.enqueue_for_event(newer_event)
    newer = push_intent_for(newer_event, fixture.recipient_user.id, rotated.id)
    assert {:discard, {:notification_status, 410}} = perform(newer)
    assert_receive {:push_delivery, _}
    assert Repo.get!(PushSubscription, rotated.id).status == :stale
  end

  defp notification_fixture(suffix \\ "worker-secret") do
    owner = Fixtures.account_fixture()
    recipient = Fixtures.user_fixture(owner).user
    recipient_login = authenticate_fixture_user(owner, recipient)
    owner_subject = Fixtures.subject(owner)

    recipient_subject = %{
      tenant_id: owner.tenant.id,
      user_id: recipient.id,
      device_id: recipient_login.device.id,
      session_id: recipient_login.session.id,
      role: recipient.role,
      request_id: "push-worker-test"
    }

    {:ok, conversation} =
      Conversations.create(
        %{
          title: "Push delivery",
          kind: "group",
          visibility: "private",
          member_ids: [recipient.id]
        },
        owner_subject
      )

    endpoint = "https://push.example.test/send/#{suffix}?capability=private"

    {:ok, %{subscription: subscription}} =
      PushSubscriptions.register(subscription_attrs(endpoint), recipient_subject)

    {:ok, _preference} =
      Notifications.update_preferences(
        %{email_enabled: false, push_enabled: true, in_app_enabled: false},
        recipient_subject
      )

    event =
      %OutboxEvent{}
      |> OutboxEvent.changeset(%{
        tenant_id: owner.tenant.id,
        event_type: "message.created.v1",
        aggregate_type: "message",
        aggregate_id: Ecto.UUID.generate(),
        payload: %{
          "conversation_id" => conversation.id,
          "sender_user_id" => owner.user.id,
          "mentioned_user_ids" => []
        },
        available_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    assert :ok = Notifications.enqueue_for_event(event)
    intent = push_intent_for(event, recipient.id, subscription.id)

    %{
      owner: owner,
      owner_subject: owner_subject,
      recipient_subject: recipient_subject,
      recipient_user: recipient,
      subscription: subscription,
      event: event,
      intent: intent,
      endpoint: endpoint
    }
  end

  defp push_intent_for(event, user_id, subscription_id) do
    Repo.get_by!(Intent,
      tenant_id: event.tenant_id,
      user_id: user_id,
      channel: :push,
      push_subscription_id: subscription_id,
      idempotency_key: "outbox:#{event.id}:user:#{user_id}:push:#{subscription_id}"
    )
  end

  defp duplicate_event(event) do
    %OutboxEvent{}
    |> OutboxEvent.changeset(%{
      tenant_id: event.tenant_id,
      event_type: event.event_type,
      aggregate_type: event.aggregate_type,
      aggregate_id: Ecto.UUID.generate(),
      payload: event.payload,
      available_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp authenticate_fixture_user(owner, user) do
    suffix = user.email |> String.split(["member-", "@"], trim: true) |> hd()

    {:ok, login} =
      Accounts.authenticate(
        owner.tenant.slug,
        user.email,
        "correct-horse-battery-#{suffix}",
        %{name: "Push browser", platform: "test"}
      )

    login
  end

  defp subscription_attrs(endpoint, auth \\ @auth) do
    %{endpoint: endpoint, expiration_time: nil, keys: %{p256dh: @p256dh, auth: auth}}
  end

  defp perform(intent) do
    CommsWorkers.NotificationWorker.perform(%Oban.Job{args: %{"intent_id" => intent.id}})
  end

  defp restore(application, key, nil), do: Application.delete_env(application, key)
  defp restore(application, key, value), do: Application.put_env(application, key, value)
end
