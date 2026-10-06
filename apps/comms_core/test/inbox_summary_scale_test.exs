defmodule CommsCore.Messaging.InboxSummaryScaleTest do
  use CommsCore.DataCase, async: true
  alias CommsCore.{Messaging, Repo}
  alias CommsCore.Accounts.{Device, User}
  alias CommsCore.Conversations.{Conversation, Membership}
  alias CommsCore.Messaging.Message
  alias CommsTestSupport.Fixtures

  test "every distinct sender is labeled through the 500-conversation limit with bounded identity batches" do
    account = Fixtures.account_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(1..500, fn index ->
        %{
          index: index,
          user: Ecto.UUID.generate(),
          device: Ecto.UUID.generate(),
          conversation: Ecto.UUID.generate()
        }
      end)

    assert {500, nil} =
             Repo.insert_all(
               User,
               Enum.map(rows, fn row ->
                 %{
                   id: row.user,
                   tenant_id: account.tenant.id,
                   display_name: "Sender #{row.index}",
                   external_subject: "local:inbox-scale-#{row.user}",
                   email: "scale-#{row.user}@example.test",
                   account_type: :human,
                   access_scope: :workspace,
                   status: :active,
                   role: :member,
                   inserted_at: now,
                   updated_at: now
                 }
               end)
             )

    assert {500, nil} =
             Repo.insert_all(
               Device,
               Enum.map(rows, fn row ->
                 %{
                   id: row.device,
                   tenant_id: account.tenant.id,
                   user_id: row.user,
                   name: "Fixture",
                   platform: "test",
                   inserted_at: now,
                   updated_at: now
                 }
               end)
             )

    assert {500, nil} =
             Repo.insert_all(
               Conversation,
               Enum.map(rows, fn row ->
                 %{
                   id: row.conversation,
                   tenant_id: account.tenant.id,
                   created_by_user_id: account.user.id,
                   kind: :group,
                   visibility: :private,
                   title: "Scale #{row.index}",
                   content_mode: :server_readable,
                   next_sequence: 2,
                   inserted_at: now,
                   updated_at: now
                 }
               end)
             )

    assert {500, nil} =
             Repo.insert_all(
               Membership,
               Enum.map(rows, fn row ->
                 %{
                   id: Ecto.UUID.generate(),
                   tenant_id: account.tenant.id,
                   conversation_id: row.conversation,
                   user_id: account.user.id,
                   role: :owner,
                   joined_at: now,
                   inserted_at: now,
                   updated_at: now
                 }
               end)
             )

    assert {500, nil} =
             Repo.insert_all(
               Message,
               Enum.map(rows, fn row ->
                 %{
                   id: Ecto.UUID.generate(),
                   tenant_id: account.tenant.id,
                   conversation_id: row.conversation,
                   sender_user_id: row.user,
                   sender_device_id: row.device,
                   client_message_id: "scale-#{row.index}",
                   conversation_sequence: 1,
                   body: "Message #{row.index}",
                   metadata: %{},
                   status: :active,
                   inserted_at: now
                 }
               end)
             )

    handler = {__MODULE__, make_ref()}
    parent = self()

    assert :ok =
             :telemetry.attach(
               handler,
               [:comms_core, :repo, :query],
               fn _, _, metadata, target ->
                 if self() == target and
                      String.starts_with?(
                        metadata.query,
                        ~s(SELECT u0."id", u0."display_name", u0."status" FROM "users")
                      ) do
                   send(target, {:identity_batch, metadata.params})
                 end
               end,
               parent
             )

    on_exit(fn -> :telemetry.detach(handler) end)

    for {count, batches} <- [{200, 1}, {201, 2}, {500, 3}] do
      selected = Enum.take(rows, count)

      assert {:ok, summaries} =
               Messaging.inbox_summaries(
                 Enum.map(selected, & &1.conversation),
                 Fixtures.subject(account)
               )

      assert map_size(summaries) == count

      for row <- selected do
        assert summaries[row.conversation].message.sender_display_name == "Sender #{row.index}"
      end

      for _ <- 1..batches do
        assert_receive {:identity_batch, [_tenant_id, ids]}
        assert length(ids) <= 200
      end

      refute_received {:identity_batch, _}
    end

    assert {:error, :invalid_inbox_query} =
             Messaging.inbox_summaries(
               List.duplicate(account.conversation.id, 501),
               Fixtures.subject(account)
             )
  end
end
