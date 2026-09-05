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

  test "unread filtering reaches an older unread item behind fifty newer read notifications" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    older = insert_intent(account)
    timestamp = DateTime.add(now(), 10, :second)

    for _ <- 1..50 do
      account
      |> insert_intent(%{read_at: timestamp})
      |> Ecto.Changeset.change(inserted_at: timestamp)
      |> Repo.update!()
    end

    assert {:ok, recent} = Notifications.list_in_app(subject)
    assert length(recent.notifications) == 50
    assert recent.unread_count == 1
    assert recent.has_more
    refute older.id in Enum.map(recent.notifications, & &1.id)

    assert {:ok, unread} = Notifications.list_in_app(subject, %{"filter" => "unread"})
    assert Enum.map(unread.notifications, & &1.id) == [older.id]
    assert unread.unread_count == 1
    refute unread.has_more
    assert unread.next_cursor == nil
  end

  test "keyset pages retain tied timestamps and remain stable across inserts and dismissal" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    timestamp = now()

    intents =
      for _ <- 1..105 do
        account
        |> insert_intent()
        |> Ecto.Changeset.change(inserted_at: timestamp)
        |> Repo.update!()
      end

    assert {:ok, first} = Notifications.list_in_app(subject, %{"filter" => "unread"})
    assert length(first.notifications) == 50
    assert first.has_more
    assert first.limit == 50

    boundary = List.last(first.notifications)
    assert {:ok, _} = Notifications.dismiss_in_app(boundary.id, subject)

    newer =
      account
      |> insert_intent()
      |> Ecto.Changeset.change(inserted_at: DateTime.add(timestamp, 10, :second))
      |> Repo.update!()

    assert {:ok, second} =
             Notifications.list_in_app(subject, %{
               "filter" => "unread",
               "cursor" => first.next_cursor
             })

    assert length(second.notifications) == 50
    assert second.has_more

    assert {:ok, third} =
             Notifications.list_in_app(subject, %{
               "filter" => "unread",
               "cursor" => second.next_cursor
             })

    assert length(third.notifications) == 5
    refute third.has_more
    assert third.next_cursor == nil

    all_ids =
      Enum.map(first.notifications ++ second.notifications ++ third.notifications, & &1.id)

    assert length(Enum.uniq(all_ids)) == 105
    assert MapSet.new(all_ids) == MapSet.new(Enum.map(intents, & &1.id))
    refute newer.id in all_ids
  end

  test "cursor and filters reject malformed input and do not cross user or tenant boundaries" do
    account = Fixtures.account_fixture()
    other = Fixtures.account_fixture()
    insert_intent(account)
    insert_intent(account)
    insert_intent(other)
    subject = Fixtures.subject(account)

    assert {:ok, page} = Notifications.list_in_app(subject, %{"limit" => 1, "filter" => "unread"})
    assert page.has_more

    assert {:ok, other_page} =
             Notifications.list_in_app(Fixtures.subject(other), %{
               "filter" => "unread",
               "cursor" => page.next_cursor
             })

    assert Enum.all?(
             other_page.notifications,
             &(&1.tenant_id == other.tenant.id and &1.user_id == other.user.id)
           )

    assert {:error, :invalid_cursor} =
             Notifications.list_in_app(subject, %{"cursor" => "invalid"})

    assert {:error, :invalid_cursor} =
             Notifications.list_in_app(subject, %{"cursor" => String.duplicate("a", 513)})

    assert {:error, :invalid_cursor} =
             Notifications.list_in_app(subject, %{"cursor" => page.next_cursor})

    assert {:error, :invalid_notification_filter} =
             Notifications.list_in_app(subject, %{"filter" => "dismissed"})

    malformed =
      Jason.encode!(%{v: 1, inserted_at: 123, notification_id: false, filter: "all"})
      |> Base.url_encode64(padding: false)

    assert {:error, :invalid_cursor} =
             Notifications.list_in_app(subject, %{"cursor" => malformed})

    assert {:ok, bounded} = Notifications.list_in_app(subject, %{"limit" => 100_000})
    assert bounded.limit == 100
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
