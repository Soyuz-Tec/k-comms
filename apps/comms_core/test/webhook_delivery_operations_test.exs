defmodule CommsCore.WebhookDeliveryOperationsTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query

  alias CommsCore.{Integrations, Outbox, Repo}

  alias CommsCore.Integrations.{
    WebhookDelivery,
    WebhookDeliveryClaim,
    WebhookDispatchRequest,
    WebhookSecret
  }

  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :webhook

  test "webhook secrets are encrypted, rotation is versioned, and fanout is idempotent" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    {:ok, %{endpoint: endpoint, secret: secret}} = create_endpoint(subject, "Audit sink")

    stored_secret = Repo.get_by!(WebhookSecret, endpoint_id: endpoint.id, version: 1)
    refute stored_secret.ciphertext == secret
    assert :binary.match(stored_secret.ciphertext, secret) == :nomatch

    assert {:ok, %{endpoint: rotated, secret: rotated_secret}} =
             Integrations.rotate_secret(endpoint.id, subject)

    assert rotated.secret_version == 2
    refute rotated_secret == secret

    event =
      insert_outbox_event!(account, %{
        payload: %{"body" => "hello", "secret" => "must-be-redacted"}
      })

    assert :ok = Integrations.enqueue_for_event(event)
    assert :ok = Integrations.enqueue_for_event(event)
    assert Repo.aggregate(WebhookDelivery, :count) == 1

    delivery = Repo.one!(WebhookDelivery)
    assert delivery.payload["data"]["secret"] == "[REDACTED]"

    other = Fixtures.account_fixture()

    assert {:error, :not_found} =
             Integrations.replay_delivery(delivery.id, Fixtures.step_up(other))
  end

  test "webhook rotation terminalizes queued old-key deliveries and refuses retired material" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    {:ok, %{endpoint: endpoint}} = create_endpoint(subject, "Rotation boundary")
    {:ok, queued} = create_delivery(account, endpoint, "webhook-rotation-boundary-0001")

    assert {:ok, %{endpoint: rotated}} = Integrations.rotate_secret(endpoint.id, subject)
    assert rotated.secret_version == 2

    terminal = Repo.get!(WebhookDelivery, queued.id)
    assert terminal.status == :failed
    assert terminal.last_error_code == "endpoint_secret_rotated"
    assert {:error, :terminal_delivery} = Integrations.claim_delivery(queued.id)

    {:ok, old_version_delivery} =
      create_delivery(account, endpoint, "webhook-rotation-boundary-0002", %{secret_version: 1})

    assert {:ok, claim} = Integrations.claim_delivery(old_version_delivery.id)
    assert {:error, :webhook_secret_unavailable} = Integrations.delivery_request(claim)
  end

  @tag :concurrency
  test "active webhook claims block destination mutation" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    {:ok, %{endpoint: endpoint}} = create_endpoint(subject, "Claim race")
    {:ok, delivery} = create_delivery(account, endpoint, "webhook-claim-race-0001")

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
      create_endpoint(subject, "Destination change", "https://hooks.example.test/original")

    attrs = delivery_attrs(account, endpoint, "webhook-destination-change-0001")
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

  defp create_endpoint(subject, name, url \\ "https://hooks.example.test/events") do
    Integrations.create_endpoint(
      %{name: name, url: url, event_types: ["message.created.v1"]},
      subject
    )
  end

  defp create_delivery(account, endpoint, idempotency_key, overrides \\ %{}) do
    account
    |> delivery_attrs(endpoint, idempotency_key)
    |> Map.merge(overrides)
    |> Integrations.create_delivery()
  end

  defp delivery_attrs(account, endpoint, idempotency_key) do
    %{
      tenant_id: account.tenant.id,
      endpoint_id: endpoint.id,
      event_type: "message.created.v1",
      payload: %{},
      idempotency_key: idempotency_key,
      secret_version: endpoint.secret_version,
      status: :pending,
      next_attempt_at: DateTime.utc_now()
    }
  end

  defp insert_outbox_event!(account, overrides) do
    attrs =
      Map.merge(
        %{
          tenant_id: account.tenant.id,
          event_type: "message.created.v1",
          aggregate_type: "message",
          aggregate_id: Ecto.UUID.generate(),
          payload: %{},
          available_at: DateTime.utc_now()
        },
        overrides
      )

    {:ok, event} = Repo.transaction(fn -> Outbox.insert_and_enqueue!(attrs) end)
    event
  end
end
