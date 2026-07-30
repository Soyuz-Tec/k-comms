defmodule CommsCore.NotificationDeliveryOperationsTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Notifications

  alias CommsCore.Notifications.{
    Attempt,
    AttemptView,
    Delivery,
    Intent,
    IntentView,
    Preference,
    PreferenceView
  }

  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :notification

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

    attrs =
      intent_attrs(account, "notification-test-key-0001", %{
        "title" => "New message",
        "body" => "Safe preview",
        "password" => "must-not-persist"
      })

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
             Notifications.create_intent(
               intent_attrs(account, "notification-test-key-0002", %{
                 "title" => "Retry",
                 "body" => "Retry this notification"
               })
             )

    assert {:ok, retried} = Notifications.retry_intent(pending.id, stepped_up_subject)
    assert %IntentView{} = retried
    assert retried.status == :pending
  end

  @tag :concurrency
  test "notification stale claims are rejected" do
    account = Fixtures.account_fixture()

    {:ok, intent} =
      Notifications.create_intent(
        intent_attrs(account, "notification-claim-race-0001", %{"title" => "Race"})
      )

    {:ok, stale_intent} = Notifications.claim_intent(intent.id)

    stale_intent.id
    |> then(&Repo.get!(Intent, &1))
    |> Intent.changeset(%{status: :retryable, claimed_at: nil, claim_token: nil})
    |> Repo.update!()

    {:ok, current_intent} = Notifications.claim_intent(intent.id)
    assert {:ok, delivered} = Notifications.record_delivery(current_intent, :ok)
    assert delivered.status == :delivered

    assert {:error, :stale_delivery_claim} =
             Notifications.record_delivery(stale_intent, {:error, :late})

    assert Repo.get!(Intent, intent.id).status == :delivered
  end

  defp intent_attrs(account, idempotency_key, payload) do
    %{
      tenant_id: account.tenant.id,
      user_id: account.user.id,
      event_type: "message.created.v1",
      channel: :email,
      destination: account.user.email,
      payload: payload,
      idempotency_key: idempotency_key
    }
  end
end
