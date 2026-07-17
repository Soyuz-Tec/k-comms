defmodule CommsCore.Notifications.InAppTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Notifications
  alias CommsCore.Notifications.{Intent, IntentView}
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  test "notification state is durable, idempotent, and scoped to the current user" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    other_user = Fixtures.user_fixture(account).user
    other_account = Fixtures.account_fixture()

    unread = insert_intent(account)
    already_read = insert_intent(account, %{read_at: now()})
    dismissed = insert_intent(account, %{read_at: now(), dismissed_at: now()})
    email = insert_intent(account, %{channel: :email})

    other_user_intent =
      insert_intent(account, %{user_id: other_user.id, destination: other_user.email})

    _other_tenant_intent = insert_intent(other_account)

    _recovery =
      insert_intent(account, %{event_type: "account.password_recovery.requested.v1"})

    assert {:ok, result} = Notifications.list_in_app(subject)
    assert Enum.all?(result.notifications, &match?(%IntentView{}, &1))

    assert Enum.map(result.notifications, & &1.id) |> MapSet.new() ==
             MapSet.new([unread.id, already_read.id])

    assert result.unread_count == 1
    refute email.id in Enum.map(result.notifications, & &1.id)
    refute dismissed.id in Enum.map(result.notifications, & &1.id)

    assert {:ok, read} = Notifications.mark_in_app_read(unread.id, subject)
    assert read.read_at
    assert {:ok, replayed_read} = Notifications.mark_in_app_read(unread.id, subject)
    assert replayed_read.read_at == read.read_at
    assert {:ok, 0} = Notifications.unread_count(subject)

    assert {:error, :not_found} =
             Notifications.mark_in_app_read(other_user_intent.id, subject)

    assert {:ok, dismissed_read} = Notifications.dismiss_in_app(unread.id, subject)
    assert dismissed_read.dismissed_at
    assert {:ok, replayed_dismiss} = Notifications.dismiss_in_app(unread.id, subject)
    assert replayed_dismiss.dismissed_at == dismissed_read.dismissed_at

    insert_intent(account)
    insert_intent(account)

    assert {:ok, bulk_result} = Notifications.mark_all_in_app_read(subject)
    assert bulk_result.updated_count == 2
    assert {:ok, current_unread_count} = Notifications.unread_count(subject)
    assert bulk_result.unread_count == current_unread_count

    assert Repo.get!(Intent, other_user_intent.id).read_at == nil
  end

  test "database rejects user state on non-in-app delivery channels" do
    account = Fixtures.account_fixture()

    assert {:error, changeset} =
             account
             |> intent_attrs(%{channel: :email, read_at: now()})
             |> then(&Intent.changeset(%Intent{}, &1))
             |> Repo.insert()

    assert {"is invalid", metadata} = changeset.errors[:read_at]
    assert metadata[:constraint_name] == "notification_intents_user_state_in_app_only"
  end

  defp insert_intent(account, overrides \\ %{}) do
    account
    |> intent_attrs(overrides)
    |> then(&Intent.changeset(%Intent{}, &1))
    |> Repo.insert!()
  end

  defp intent_attrs(account, overrides) do
    timestamp = now()

    Map.merge(
      %{
        tenant_id: account.tenant.id,
        user_id: account.user.id,
        event_type: "message.created.v1",
        channel: :in_app,
        destination: account.user.id,
        payload: %{
          "conversation_id" => account.conversation.id,
          "message_id" => Ecto.UUID.generate()
        },
        idempotency_key: "in-app-test:#{Ecto.UUID.generate()}",
        status: :delivered,
        next_attempt_at: timestamp,
        delivered_at: timestamp
      },
      overrides
    )
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
