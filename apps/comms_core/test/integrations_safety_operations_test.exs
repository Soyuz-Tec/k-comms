defmodule CommsCore.IntegrationsSafetyOperationsTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Accounts, Attachments}
  alias CommsCore.Attachments.{Attachment, AttachmentView, ScanAttempt}
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Integrations
  alias CommsCore.Outbox.Event

  alias CommsCore.Integrations.{
    WebhookDelivery,
    WebhookDeliveryClaim,
    WebhookDispatchRequest,
    WebhookEndpoint,
    WebhookSecret,
    WebhookSubscription
  }

  alias CommsCore.Notifications
  alias CommsCore.Notifications.{Attempt, Intent, Preference}
  alias CommsCore.Notifications.{AttemptView, Delivery, IntentView, PreferenceView}
  alias CommsCore.Operations
  alias CommsTestSupport.Fixtures

  test "release metadata accepts only a full immutable Git revision" do
    previous = System.get_env("K_COMMS_RELEASE_REVISION")

    on_exit(fn ->
      if previous,
        do: System.put_env("K_COMMS_RELEASE_REVISION", previous),
        else: System.delete_env("K_COMMS_RELEASE_REVISION")
    end)

    System.put_env("K_COMMS_RELEASE_REVISION", String.duplicate("A", 40))
    assert Operations.release_revision() == String.duplicate("a", 40)

    System.put_env("K_COMMS_RELEASE_REVISION", "main")
    assert Operations.release_revision() == "development"
  end

  test "attachments remain unavailable until a clean scanner verdict and block malicious files" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, pending} =
             Attachments.create_intent(
               %{
                 file_name: "evidence.txt",
                 content_type: "text/plain",
                 byte_size: 12,
                 checksum_sha256: String.duplicate("a", 64)
               },
               subject
             )

    assert %AttachmentView{} = pending
    refute match?(%Attachment{}, pending)

    assert {:ok, uploaded} =
             Attachments.mark_uploaded(
               pending.id,
               String.duplicate("a", 64),
               identity(String.duplicate("a", 64), "clean"),
               subject
             )

    assert %AttachmentView{} = uploaded
    refute match?(%Attachment{}, uploaded)
    assert uploaded.status == :uploaded
    assert uploaded.scan_status == :pending
    refute uploaded.status == :ready

    assert {:ok, scanning} = Attachments.claim_scan(uploaded.id)

    assert {:ok, ready} =
             Attachments.record_scan(
               scanning,
               {:ok, %{verdict: :clean, provider: "test", provider_reference: "scan-1"}}
             )

    assert ready.status == :ready
    assert ready.scan_status == :clean
    assert ready.scan_attempts == 1
    assert Repo.aggregate(ScanAttempt, :count) == 1

    assert {:ok, malicious_pending} =
             Attachments.create_intent(
               %{
                 file_name: "bad.txt",
                 content_type: "text/plain",
                 byte_size: 8,
                 checksum_sha256: String.duplicate("b", 64)
               },
               subject
             )

    assert {:ok, malicious_uploaded} =
             Attachments.mark_uploaded(
               malicious_pending.id,
               String.duplicate("b", 64),
               identity(String.duplicate("b", 64), "blocked"),
               subject
             )

    assert {:ok, malicious_scanning} = Attachments.claim_scan(malicious_uploaded.id)

    assert {:ok, quarantined} =
             Attachments.record_scan(
               malicious_scanning,
               {:ok, %{verdict: :malicious, provider: "test"}}
             )

    assert quarantined.status == :quarantined
    assert quarantined.scan_status == :blocked
    assert quarantined.quarantined_at
  end

  test "notification intents have a tenant-scoped idempotent ledger" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, preference} =
             Notifications.update_preferences(
               %{email_enabled: true, push_enabled: false, in_app_enabled: true},
               subject
             )

    assert preference.user_id == account.user.id
    assert %PreferenceView{} = preference
    refute match?(%Preference{}, preference)

    attrs = %{
      tenant_id: account.tenant.id,
      user_id: account.user.id,
      event_type: "message.created.v1",
      channel: :email,
      destination: account.user.email,
      payload: %{
        "title" => "New message",
        "body" => "Safe preview",
        "password" => "must-not-persist"
      },
      idempotency_key: "notification-test-key-0001"
    }

    assert {:ok, first} = Notifications.create_intent(attrs)
    assert {:ok, duplicate} = Notifications.create_intent(attrs)
    assert %IntentView{} = first
    refute match?(%Intent{}, first)
    assert first.id == duplicate.id
    assert Repo.aggregate(Intent, :count) == 1
    refute Map.has_key?(first.payload, "password")

    assert {:ok, claimed} = Notifications.claim_intent(first.id)
    assert %Delivery{} = claimed
    refute inspect(claimed) =~ account.user.email
    refute inspect(claimed) =~ "Safe preview"
    refute inspect(claimed) =~ claimed.claim_token

    assert {:ok, delivered} =
             Notifications.record_delivery(
               claimed,
               {:ok, %{provider: "test-http", http_status: 202, provider_message_id: "msg-1"}}
             )

    assert delivered.status == :delivered
    assert %IntentView{} = delivered
    assert delivered.attempt_count == 1
    assert Repo.aggregate(Attempt, :count) == 1
    assert {:ok, [%AttemptView{}]} = Notifications.list_attempts(subject)
    assert {:error, :step_up_required} = Notifications.retry_intent(delivered.id, subject)

    stepped_up_subject = Fixtures.step_up(account, subject)

    assert {:error, :already_delivered} =
             Notifications.retry_intent(delivered.id, stepped_up_subject)

    assert {:ok, pending} =
             Notifications.create_intent(%{
               attrs
               | idempotency_key: "notification-test-key-0002",
                 payload: %{"title" => "Retry", "body" => "Retry this notification"}
             })

    assert {:ok, retried} = Notifications.retry_intent(pending.id, stepped_up_subject)
    assert %IntentView{} = retried
    assert retried.status == :pending
  end

  test "webhook secrets are encrypted, rotation is versioned, and fanout is idempotent" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, %{endpoint: endpoint, secret: secret}} =
             Integrations.create_endpoint(
               %{
                 name: "Audit sink",
                 url: "https://hooks.example.test/events",
                 event_types: ["message.created.v1"]
               },
               subject
             )

    stored_secret = Repo.get_by!(WebhookSecret, endpoint_id: endpoint.id, version: 1)
    refute stored_secret.ciphertext == secret
    assert :binary.match(stored_secret.ciphertext, secret) == :nomatch

    assert {:ok, %{endpoint: rotated, secret: rotated_secret}} =
             Integrations.rotate_secret(endpoint.id, subject)

    assert rotated.secret_version == 2
    refute rotated_secret == secret

    event =
      %OutboxEvent{}
      |> OutboxEvent.changeset(%{
        tenant_id: account.tenant.id,
        event_type: "message.created.v1",
        aggregate_type: "message",
        aggregate_id: Ecto.UUID.generate(),
        payload: %{"body" => "hello", "secret" => "must-be-redacted"},
        available_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    assert :ok = Integrations.enqueue_for_event(Event.new(event))
    assert :ok = Integrations.enqueue_for_event(Event.new(event))
    assert Repo.aggregate(WebhookDelivery, :count) == 1

    delivery = Repo.one!(WebhookDelivery)
    assert delivery.payload["data"]["secret"] == "[REDACTED]"

    other = Fixtures.account_fixture()

    assert {:error, :not_found} =
             Integrations.replay_delivery(delivery.id, Fixtures.step_up(other))
  end

  test "operations snapshot is tenant-scoped and exposes no destination or secret material" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    previous_secret = Application.get_env(:comms_core, :platform_role_management_secret)
    secret = String.duplicate("operations-platform-secret-", 2)

    Application.put_env(:comms_core, :platform_role_management_secret, secret)

    on_exit(fn ->
      if previous_secret,
        do: Application.put_env(:comms_core, :platform_role_management_secret, previous_secret),
        else: Application.delete_env(:comms_core, :platform_role_management_secret)
    end)

    assert {:ok, snapshot} = Operations.snapshot(subject)
    assert is_list(snapshot.queues)
    assert is_map(snapshot.notifications)
    assert is_map(snapshot.webhooks)
    assert is_map(snapshot.attachments)

    encoded = inspect(snapshot)
    refute encoded =~ "password_hash"
    refute encoded =~ "destination"
    refute encoded =~ "ciphertext"

    assert {:error, :forbidden} = Operations.platform_snapshot(subject)

    assert {:ok, _user} =
             Accounts.set_platform_role_from_console(account.user.id, :platform_operator, %{
               grant_token: secret,
               actor: "operations-test",
               reason: "verify platform operations authorization",
               ttl_seconds: 3600
             })

    platform_subject = Accounts.subject_for_session(account.session)

    assert {:ok, platform} = Operations.platform_snapshot(platform_subject)

    assert platform.database.status == :available
    assert is_binary(platform.release_revision)
  end

  test "a stale clean scanner result cannot reverse a newer blocked verdict" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    checksum = String.duplicate("c", 64)

    {:ok, pending} =
      Attachments.create_intent(
        %{
          file_name: "race.txt",
          content_type: "text/plain",
          byte_size: 16,
          checksum_sha256: checksum
        },
        subject
      )

    {:ok, uploaded} =
      Attachments.mark_uploaded(pending.id, checksum, identity(checksum, "race"), subject)

    {:ok, first_claim} = Attachments.claim_scan(uploaded.id)

    first_claim_schema = Repo.get!(Attachment, first_claim.id)

    first_claim_schema
    |> Attachment.changeset(%{
      status: :scan_failed,
      scan_status: :failed,
      scan_claim_token: nil,
      scan_claimed_at: nil
    })
    |> Repo.update!()

    {:ok, second_claim} = Attachments.claim_scan(uploaded.id)

    assert {:ok, blocked} =
             Attachments.record_scan(
               second_claim,
               {:ok, %{verdict: :malicious, provider: "test"}}
             )

    assert blocked.status == :quarantined

    assert {:error, :stale_scan_claim} =
             Attachments.record_scan(first_claim, {:ok, %{verdict: :clean, provider: "test"}})

    persisted = Repo.get!(Attachment, uploaded.id)
    assert persisted.status == :quarantined
    assert persisted.scan_status == :blocked
  end

  test "notification stale claims are rejected and active webhook claims block destination mutation" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    {:ok, intent} =
      Notifications.create_intent(%{
        tenant_id: account.tenant.id,
        user_id: account.user.id,
        event_type: "message.created.v1",
        channel: :email,
        destination: account.user.email,
        payload: %{"title" => "Race"},
        idempotency_key: "notification-claim-race-0001"
      })

    {:ok, stale_intent} = Notifications.claim_intent(intent.id)

    Intent
    |> Repo.get!(stale_intent.id)
    |> Intent.changeset(%{status: :retryable, claimed_at: nil, claim_token: nil})
    |> Repo.update!()

    {:ok, current_intent} = Notifications.claim_intent(intent.id)
    assert {:ok, delivered} = Notifications.record_delivery(current_intent, :ok)
    assert delivered.status == :delivered

    assert {:error, :stale_delivery_claim} =
             Notifications.record_delivery(stale_intent, {:error, :late})

    assert Repo.get!(Intent, intent.id).status == :delivered

    {:ok, %{endpoint: endpoint}} =
      Integrations.create_endpoint(
        %{
          name: "Claim race",
          url: "https://hooks.example.test/events",
          event_types: ["message.created.v1"]
        },
        subject
      )

    {:ok, delivery} =
      Integrations.create_delivery(%{
        tenant_id: account.tenant.id,
        endpoint_id: endpoint.id,
        event_type: "message.created.v1",
        payload: %{},
        idempotency_key: "webhook-claim-race-0001",
        secret_version: endpoint.secret_version,
        status: :pending,
        next_attempt_at: DateTime.utc_now()
      })

    {:ok, claimed_delivery} = Integrations.claim_delivery(delivery.id)
    assert %WebhookDeliveryClaim{} = claimed_delivery
    refute inspect(claimed_delivery) =~ claimed_delivery.claim_token

    assert {:ok, %WebhookDispatchRequest{url: "https://hooks.example.test/events"} = request} =
             Integrations.delivery_request(claimed_delivery)

    refute inspect(request) =~ request.secret
    refute inspect(request) =~ "body"

    assert {:error, :conflict} =
             Integrations.update_endpoint(
               endpoint.id,
               %{url: "https://hooks.example.test/changed"},
               subject
             )

    assert {:error, :conflict} = Integrations.rotate_secret(endpoint.id, subject)
    assert {:error, :conflict} = Integrations.disable_endpoint(endpoint.id, subject)

    assert {:ok, :recorded} =
             Integrations.record_delivery(
               claimed_delivery,
               {:error, :permanent, :operator_finalized}
             )

    assert Repo.get!(WebhookDelivery, delivery.id).status == :failed
    assert {:ok, _disabled} = Integrations.disable_endpoint(endpoint.id, subject)

    assert {:error, :endpoint_disabled} = Integrations.delivery_request(claimed_delivery)
    assert Repo.get!(WebhookDelivery, delivery.id).status == :failed
  end

  test "URL changes terminalize queued deliveries before the new destination can materialize" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    {:ok, %{endpoint: endpoint}} =
      Integrations.create_endpoint(
        %{
          name: "Destination change",
          url: "https://hooks.example.test/original",
          event_types: ["message.created.v1"]
        },
        subject
      )

    attrs = %{
      tenant_id: account.tenant.id,
      endpoint_id: endpoint.id,
      event_type: "message.created.v1",
      payload: %{"sensitive" => "queued-for-original"},
      idempotency_key: "webhook-destination-change-0001",
      secret_version: endpoint.secret_version,
      status: :pending,
      next_attempt_at: DateTime.utc_now()
    }

    assert {:ok, delivery} = Integrations.create_delivery(attrs)

    assert {:ok, changed} =
             Integrations.update_endpoint(
               endpoint.id,
               %{url: "https://hooks.example.test/replacement"},
               subject
             )

    assert changed.url == "https://hooks.example.test/replacement"

    terminal = Repo.get!(WebhookDelivery, delivery.id)
    assert terminal.status == :failed
    assert terminal.last_error_code == "endpoint_configuration_changed"
    assert {:error, :terminal_delivery} = Integrations.claim_delivery(delivery.id)

    Repo.delete_all(
      from(job in Oban.Job,
        where:
          job.worker == "CommsWorkers.WebhookWorker" and
            fragment("?->>'delivery_id' = ?", job.args, ^delivery.id)
      )
    )

    assert {:ok, idempotent} = Integrations.create_delivery(attrs)
    assert idempotent.id == terminal.id
    assert idempotent.status == :failed

    refute Repo.exists?(
             from(job in Oban.Job,
               where:
                 job.worker == "CommsWorkers.WebhookWorker" and
                   fragment("?->>'delivery_id' = ?", job.args, ^delivery.id)
             )
           )
  end

  test "fanout cannot insert a pre-change delivery after destination discovery" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    {:ok, %{endpoint: endpoint}} =
      Integrations.create_endpoint(
        %{
          name: "Fanout destination race",
          url: "https://hooks.example.test/original",
          event_types: ["message.created.v1"]
        },
        subject
      )

    event =
      %OutboxEvent{}
      |> OutboxEvent.changeset(%{
        tenant_id: account.tenant.id,
        event_type: "message.created.v1",
        aggregate_type: "message",
        aggregate_id: Ecto.UUID.generate(),
        payload: %{"sensitive" => "bound-to-original-destination"},
        available_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    parent = self()
    handler_id = {__MODULE__, :fanout_destination_race, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler_id,
               [:comms_core, :repo, :query],
               fn _event, _measurements, metadata, test_pid ->
                 query = Map.get(metadata, :query, "")

                 if String.contains?(query, ~s(FROM "webhook_endpoints")) and
                      String.contains?(query, ~s(JOIN "webhook_subscriptions")) do
                   caller = self()
                   send(test_pid, {:fanout_destination_discovered, caller})

                   receive do
                     {:continue_fanout, ^test_pid} -> :ok
                   after
                     5_000 -> exit(:fanout_destination_barrier_timeout)
                   end
                 end
               end,
               parent
             )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    enqueue_task = Task.async(fn -> Integrations.enqueue_for_event(Event.new(event)) end)
    assert_receive {:fanout_destination_discovered, enqueue_pid}, 5_000

    assert {:ok, changed} =
             Integrations.update_endpoint(
               endpoint.id,
               %{url: "https://hooks.example.test/replacement"},
               subject
             )

    assert changed.url == "https://hooks.example.test/replacement"
    send(enqueue_pid, {:continue_fanout, parent})
    assert :ok = Task.await(enqueue_task, 5_000)

    terminal = Repo.get_by!(WebhookDelivery, outbox_event_id: event.id)
    assert terminal.status == :failed
    assert terminal.last_error_code == "endpoint_configuration_changed"
    assert {:error, :terminal_delivery} = Integrations.claim_delivery(terminal.id)

    refute Repo.exists?(
             from(job in Oban.Job,
               where:
                 job.worker == "CommsWorkers.WebhookWorker" and
                   fragment("?->>'delivery_id' = ?", job.args, ^terminal.id)
             )
           )

    assert :ok = :telemetry.detach(handler_id)
    assert :ok = Integrations.enqueue_for_event(Event.new(event))
    assert Repo.aggregate(WebhookDelivery, :count) == 1
    assert Repo.get!(WebhookDelivery, terminal.id).status == :failed

    assert {:ok, replayed} = Integrations.replay_delivery(terminal.id, subject)
    assert {:ok, claimed} = Integrations.claim_delivery(replayed.id)

    assert {:ok, %{url: "https://hooks.example.test/replacement"}} =
             Integrations.delivery_request(claimed)
  end

  test "replay holds the endpoint lock until its delivery is visible to destination updates" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    {:ok, %{endpoint: endpoint}} =
      Integrations.create_endpoint(
        %{
          name: "Replay destination race",
          url: "https://hooks.example.test/original",
          event_types: ["message.created.v1"]
        },
        subject
      )

    {:ok, source} =
      Integrations.create_delivery(%{
        tenant_id: account.tenant.id,
        endpoint_id: endpoint.id,
        event_type: "message.created.v1",
        payload: %{"sensitive" => "replay-only-to-locked-destination"},
        idempotency_key: "webhook-replay-destination-race-source",
        secret_version: endpoint.secret_version,
        status: :pending,
        next_attempt_at: DateTime.utc_now()
      })

    parent = self()
    handler_id = {__MODULE__, :replay_destination_race, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler_id,
               [:comms_core, :repo, :query],
               fn _event, _measurements, metadata, %{handler_id: id, parent: test_pid} ->
                 query = Map.get(metadata, :query, "")

                 if String.contains?(query, ~s(FROM "webhook_endpoints")) and
                      String.contains?(query, "FOR UPDATE") do
                   :telemetry.detach(id)
                   caller = self()
                   send(test_pid, {:replay_endpoint_locked, caller})

                   receive do
                     {:continue_replay, ^test_pid} -> :ok
                   after
                     5_000 -> exit(:replay_destination_barrier_timeout)
                   end
                 end
               end,
               %{handler_id: handler_id, parent: parent}
             )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    replay_task = Task.async(fn -> Integrations.replay_delivery(source.id, subject) end)
    assert_receive {:replay_endpoint_locked, replay_pid}, 5_000

    update_task =
      Task.async(fn ->
        Integrations.update_endpoint(
          endpoint.id,
          %{url: "https://hooks.example.test/replacement"},
          subject
        )
      end)

    assert Task.yield(update_task, 100) == nil
    send(replay_pid, {:continue_replay, parent})

    assert {:ok, replayed} = Task.await(replay_task, 5_000)
    assert {:ok, changed} = Task.await(update_task, 5_000)
    assert changed.url == "https://hooks.example.test/replacement"

    terminal = Repo.get!(WebhookDelivery, replayed.id)
    assert terminal.status == :failed
    assert terminal.last_error_code == "endpoint_configuration_changed"
  end

  test "tenant attachment size policy is enforced before an upload intent is issued" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    %CommsCore.Administration.TenantSettings{}
    |> CommsCore.Administration.TenantSettings.changeset(%{
      tenant_id: account.tenant.id,
      max_attachment_bytes: 10
    })
    |> Repo.insert!()

    assert {:error, :invalid_attachment_size} =
             Attachments.create_intent(
               %{
                 file_name: "too-large.txt",
                 content_type: "text/plain",
                 byte_size: 11,
                 checksum_sha256: String.duplicate("d", 64)
               },
               subject
             )

    assert {:ok, _attachment} =
             Attachments.create_intent(
               %{
                 file_name: "allowed.txt",
                 content_type: "text/plain",
                 byte_size: 10,
                 checksum_sha256: String.duplicate("e", 64)
               },
               subject
             )
  end

  test "integration composite foreign keys reject every cross-tenant relationship" do
    first = Fixtures.account_fixture()
    second = Fixtures.account_fixture()
    first_subject = Fixtures.step_up(first)
    second_subject = Fixtures.step_up(second)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    checksum = String.duplicate("f", 64)

    {:ok, attachment} =
      Attachments.create_intent(
        %{
          file_name: "tenant-bound.txt",
          content_type: "text/plain",
          byte_size: 4,
          checksum_sha256: checksum
        },
        first_subject
      )

    {:ok, intent} =
      Notifications.create_intent(%{
        tenant_id: first.tenant.id,
        user_id: first.user.id,
        event_type: "message.created.v1",
        channel: :email,
        destination: first.user.email,
        payload: %{},
        idempotency_key: "tenant-fk-intent-0001"
      })

    {:ok, %{endpoint: first_endpoint}} =
      Integrations.create_endpoint(
        %{
          name: "First endpoint",
          url: "https://hooks.example.test/first",
          event_types: ["message.created.v1"]
        },
        first_subject
      )

    {:ok, %{endpoint: second_endpoint}} =
      Integrations.create_endpoint(
        %{
          name: "Second endpoint",
          url: "https://hooks.example.test/second",
          event_types: ["message.created.v1"]
        },
        second_subject
      )

    outbox =
      %OutboxEvent{}
      |> OutboxEvent.changeset(%{
        tenant_id: first.tenant.id,
        event_type: "message.created.v1",
        aggregate_type: "message",
        aggregate_id: Ecto.UUID.generate(),
        payload: %{},
        available_at: now
      })
      |> Repo.insert!()

    assert_tenant_fk(
      ScanAttempt.changeset(%ScanAttempt{}, %{
        tenant_id: second.tenant.id,
        attachment_id: attachment.id,
        attempt_number: 1,
        provider: "test",
        status: :failed,
        started_at: now,
        completed_at: now
      }),
      :attachment_id
    )

    assert_tenant_fk(
      Preference.changeset(%Preference{}, %{
        tenant_id: second.tenant.id,
        user_id: first.user.id
      }),
      :user_id
    )

    assert_tenant_fk(
      Intent.changeset(%Intent{}, %{
        tenant_id: second.tenant.id,
        user_id: first.user.id,
        event_type: "message.created.v1",
        channel: :email,
        destination: first.user.email,
        payload: %{},
        idempotency_key: "tenant-fk-intent-0002",
        status: :pending,
        next_attempt_at: now
      }),
      :user_id
    )

    assert_tenant_fk(
      Attempt.changeset(%Attempt{}, %{
        tenant_id: second.tenant.id,
        intent_id: intent.id,
        attempt_number: 1,
        provider: "test",
        status: :failed,
        started_at: now,
        completed_at: now
      }),
      :intent_id
    )

    assert_tenant_fk(
      WebhookEndpoint.changeset(%WebhookEndpoint{}, %{
        tenant_id: second.tenant.id,
        created_by_user_id: first.user.id,
        name: "Wrong creator",
        url: "https://hooks.example.test/wrong",
        status: :active,
        secret_version: 1
      }),
      :created_by_user_id
    )

    assert_tenant_fk(
      WebhookSubscription.changeset(%WebhookSubscription{}, %{
        tenant_id: second.tenant.id,
        endpoint_id: first_endpoint.id,
        event_type: "message.edited.v1"
      }),
      :endpoint_id
    )

    assert_tenant_fk(
      WebhookSecret.changeset(%WebhookSecret{}, %{
        tenant_id: second.tenant.id,
        endpoint_id: first_endpoint.id,
        version: 99,
        ciphertext: <<1>>,
        nonce: :binary.copy(<<2>>, 12),
        tag: :binary.copy(<<3>>, 16),
        key_id: "test"
      }),
      :endpoint_id
    )

    delivery_attrs = %{
      tenant_id: second.tenant.id,
      endpoint_id: first_endpoint.id,
      event_type: "message.created.v1",
      payload: %{},
      idempotency_key: "tenant-fk-delivery-0001",
      secret_version: 1,
      status: :pending,
      next_attempt_at: now
    }

    assert_tenant_fk(
      WebhookDelivery.changeset(%WebhookDelivery{}, delivery_attrs),
      :endpoint_id
    )

    assert_tenant_fk(
      WebhookDelivery.changeset(
        %WebhookDelivery{},
        Map.merge(delivery_attrs, %{
          endpoint_id: second_endpoint.id,
          outbox_event_id: outbox.id,
          idempotency_key: "tenant-fk-delivery-0002"
        })
      ),
      :outbox_event_id
    )
  end

  defp identity(checksum, suffix) do
    %{
      object_version_id: "version-#{suffix}",
      object_etag: "\"etag-#{suffix}\"",
      verified_checksum_sha256: checksum
    }
  end

  defp assert_tenant_fk(changeset, field) do
    assert {:error, rejected} = Repo.insert(changeset)
    assert {"does not exist", _metadata} = Keyword.fetch!(rejected.errors, field)
  end
end
