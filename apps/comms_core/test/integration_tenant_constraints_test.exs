defmodule CommsCore.IntegrationTenantConstraintsTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Attachments, Integrations, Notifications, Outbox, Repo}
  alias CommsCore.Attachments.ScanAttempt

  alias CommsCore.Integrations.{
    WebhookDelivery,
    WebhookEndpoint,
    WebhookSecret,
    WebhookSubscription
  }

  alias CommsCore.Notifications.{Attempt, Intent, Preference}
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :persistence

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
      create_endpoint(first_subject, "First endpoint", "first")

    {:ok, %{endpoint: second_endpoint}} =
      create_endpoint(second_subject, "Second endpoint", "second")

    outbox =
      insert_outbox_event!(%{
        tenant_id: first.tenant.id,
        event_type: "message.created.v1",
        aggregate_type: "message",
        aggregate_id: Ecto.UUID.generate(),
        payload: %{},
        available_at: now
      })

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

  defp create_endpoint(subject, name, suffix) do
    Integrations.create_endpoint(
      %{
        name: name,
        url: "https://hooks.example.test/#{suffix}",
        event_types: ["message.created.v1"]
      },
      subject
    )
  end

  defp insert_outbox_event!(attrs) do
    {:ok, event} = Repo.transaction(fn -> Outbox.insert_and_enqueue!(attrs) end)
    event
  end

  defp assert_tenant_fk(changeset, field) do
    assert {:error, rejected} = Repo.insert(changeset)
    assert {"does not exist", _metadata} = Keyword.fetch!(rejected.errors, field)
  end
end
