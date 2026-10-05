defmodule CommsCore.UCNotificationAvailabilityTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Accounts, Conversations, Notifications, Repo}
  alias CommsCore.Notifications.{Attempt, Intent}
  alias CommsCore.Outbox.Event
  alias CommsCore.Security.Password
  alias CommsTestSupport.Fixtures

  test "DND defers provider work without consuming a claim and is enforced on retry" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, _} = Accounts.update_availability(%{presence_state: "dnd"}, subject)
    assert {:ok, intent} = Notifications.create_intent(intent(account, "uc-dnd-test-0001"))
    assert {:error, {:availability_deferred, 3_600}} = Notifications.claim_intent(intent.id)

    deferred = Repo.get!(Intent, intent.id)
    assert deferred.status == :pending
    assert deferred.claim_token == nil
    assert deferred.attempt_count == 0
    assert Repo.aggregate(Attempt, :count) == 0

    assert {:ok, _} = Notifications.retry_intent(intent.id, Fixtures.step_up(account, subject))
    assert {:error, {:availability_deferred, 3_600}} = Notifications.claim_intent(intent.id)

    assert {:ok, _} = Accounts.update_availability(%{presence_state: "available"}, subject)
    assert {:ok, _} = Notifications.retry_intent(intent.id, Fixtures.step_up(account, subject))
    assert {:ok, delivery} = Notifications.claim_intent(intent.id)
    assert delivery.user_id == account.user.id
    assert delivery.attempt_count == 0
  end

  test "explicit account recovery remains claimable during DND" do
    account = Fixtures.account_fixture()

    assert {:ok, _} =
             Accounts.update_availability(%{presence_state: "dnd"}, Fixtures.subject(account))

    attrs =
      intent(account, "uc-recovery-dnd-0001")
      |> Map.put(:event_type, "account.password_recovery.requested.v1")
      |> Map.put(:payload, %{"recovery_request_id" => Ecto.UUID.generate()})

    assert {:ok, notification} = Notifications.create_intent(attrs)
    assert {:ok, _delivery} = Notifications.claim_intent(notification.id)
  end

  test "meeting reminders retain in-app state during DND and exclude other tenants and nonmembers" do
    account = Fixtures.account_fixture()

    member =
      Fixtures.user_fixture(account, %{password_hash: Password.hash("uc-member-password-fixture")})

    nonmember = Fixtures.user_fixture(account)
    other = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, conversation} =
             Conversations.create(
               %{
                 title: "Scheduled meeting",
                 kind: "group",
                 visibility: "private",
                 member_ids: [member.user.id]
               },
               subject
             )

    assert {:ok, member_session} =
             Accounts.authenticate_view(
               account.tenant.slug,
               member.user.email,
               "uc-member-password-fixture",
               %{name: "DND test browser", platform: "test"}
             )

    assert {:ok, member_context} = Accounts.access_context(member_session.session_id)

    assert {:ok, _} =
             Accounts.update_availability(
               %{presence_state: "dnd"},
               member_context.subject
             )

    meeting_id = Ecto.UUID.generate()
    occurrence_id = Ecto.UUID.generate()

    event = %Event{
      id: Ecto.UUID.generate(),
      tenant_id: account.tenant.id,
      event_type: "meeting.reminder.v1",
      aggregate_type: "meeting",
      aggregate_id: meeting_id,
      payload: %{
        "conversation_id" => conversation.id,
        "meeting_id" => meeting_id,
        "occurrence_id" => occurrence_id,
        "starts_at" => "2026-10-05T14:00:00Z"
      }
    }

    assert :ok = Notifications.enqueue_for_event(event)
    assert :ok = Notifications.enqueue_for_event(event)
    notifications = Repo.all(Intent) |> Enum.filter(&(&1.payload["event_id"] == event.id))
    assert length(notifications) == 4
    refute Enum.any?(notifications, &(&1.user_id in [nonmember.user.id, other.user.id]))
    in_app = Enum.find(notifications, &(&1.user_id == member.user.id and &1.channel == :in_app))
    assert in_app.status == :delivered
    assert in_app.payload["meeting_id"] == meeting_id
    assert in_app.payload["occurrence_id"] == occurrence_id
    assert in_app.payload["message_id"] == nil
    email = Enum.find(notifications, &(&1.user_id == member.user.id and &1.channel == :email))
    assert {:error, {:availability_deferred, 3_600}} = Notifications.claim_intent(email.id)
  end

  defp intent(account, key) do
    %{
      tenant_id: account.tenant.id,
      user_id: account.user.id,
      event_type: "message.created.v1",
      channel: :email,
      destination: account.user.email,
      payload: %{"title" => "Message"},
      idempotency_key: key
    }
  end
end
