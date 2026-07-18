defmodule CommsCore.MessagingGovernanceQueriesTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query

  alias CommsCore.Conversations

  alias CommsCore.Messaging.{
    GovernanceImpact,
    Message,
    RetentionCandidate,
    RetentionScope
  }

  alias CommsCore.{Messaging, Repo}
  alias CommsTestSupport.Fixtures

  test "governance impact returns tenant-scoped deterministic scalar identifiers" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    other_conversation = create_conversation!(subject, "Governance impact")
    empty_conversation = create_conversation!(subject, "Empty governance impact")
    user_without_messages = Fixtures.user_fixture(account).user
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    first =
      create_message!(
        account,
        account.conversation.id,
        "governance-impact-0001",
        DateTime.add(now, -300, :second)
      )

    second =
      create_message!(
        account,
        other_conversation.id,
        "governance-impact-0002",
        DateTime.add(now, -200, :second)
      )

    Message
    |> where([message], message.id == ^first.id)
    |> Repo.update_all(set: [status: :deleted, deleted_at: now])

    foreign = Fixtures.account_fixture()

    foreign_message =
      create_message!(
        foreign,
        foreign.conversation.id,
        "governance-impact-foreign",
        DateTime.add(now, -400, :second)
      )

    assert %GovernanceImpact{
             found?: true,
             message_ids: message_ids,
             conversation_ids: conversation_ids,
             user_ids: [user_id]
           } = Messaging.governance_impact(account.tenant.id, :user, account.user.id)

    assert message_ids == Enum.sort([first.id, second.id])
    assert conversation_ids == Enum.sort([account.conversation.id, other_conversation.id])
    assert user_id == account.user.id

    assert %GovernanceImpact{
             found?: true,
             message_ids: [second_id],
             conversation_ids: [conversation_id],
             user_ids: [user_id]
           } =
             Messaging.governance_impact(
               account.tenant.id,
               :conversation,
               other_conversation.id
             )

    assert second_id == second.id
    assert conversation_id == other_conversation.id
    assert user_id == account.user.id

    assert %GovernanceImpact{
             found?: true,
             message_ids: [first_id],
             conversation_ids: [conversation_id],
             user_ids: [user_id]
           } = Messaging.governance_impact(account.tenant.id, :message, first.id)

    assert first_id == first.id
    assert conversation_id == account.conversation.id
    assert user_id == account.user.id

    assert %GovernanceImpact{
             found?: false,
             message_ids: [],
             conversation_ids: [],
             user_ids: []
           } = Messaging.governance_impact(account.tenant.id, :message, foreign_message.id)

    assert %GovernanceImpact{
             found?: false,
             message_ids: [],
             conversation_ids: [],
             user_ids: []
           } =
             Messaging.governance_impact(
               account.tenant.id,
               :conversation,
               empty_conversation.id
             )

    assert %GovernanceImpact{
             found?: false,
             message_ids: [],
             conversation_ids: [],
             user_ids: []
           } =
             Messaging.governance_impact(account.tenant.id, :user, user_without_messages.id)

    refute function_exported?(GovernanceImpact, :__schema__, 1)
  end

  test "retention candidates apply per-conversation cutoffs and one global stable limit" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    other_conversation = create_conversation!(subject, "Retention candidates")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    deleted =
      create_message!(
        account,
        account.conversation.id,
        "retention-deleted-0001",
        DateTime.add(now, -600, :second)
      )

    oldest =
      create_message!(
        account,
        account.conversation.id,
        "retention-oldest-0001",
        DateTime.add(now, -500, :second)
      )

    tied_first =
      create_message!(
        account,
        other_conversation.id,
        "retention-tied-000001",
        DateTime.add(now, -400, :second)
      )

    tied_second =
      create_message!(
        account,
        other_conversation.id,
        "retention-tied-000002",
        DateTime.add(now, -400, :second)
      )

    _too_new =
      create_message!(
        account,
        account.conversation.id,
        "retention-too-new-0001",
        DateTime.add(now, -10, :second)
      )

    Message
    |> where([message], message.id == ^deleted.id)
    |> Repo.update_all(set: [status: :deleted, deleted_at: now])

    foreign = Fixtures.account_fixture()

    _foreign_oldest =
      create_message!(
        foreign,
        foreign.conversation.id,
        "retention-foreign-00001",
        DateTime.add(now, -700, :second)
      )

    scopes = [
      %RetentionScope{
        conversation_id: account.conversation.id,
        cutoff_at: DateTime.add(now, -100, :second)
      },
      %RetentionScope{
        conversation_id: other_conversation.id,
        cutoff_at: DateTime.add(now, -300, :second)
      },
      %RetentionScope{
        conversation_id: foreign.conversation.id,
        cutoff_at: now
      }
    ]

    expected_tied_order = Enum.sort([tied_first.id, tied_second.id])

    assert [
             %RetentionCandidate{
               message_id: oldest_id,
               conversation_id: oldest_conversation_id
             },
             %RetentionCandidate{
               message_id: first_tied_id,
               conversation_id: tied_conversation_id
             }
           ] = Messaging.retention_candidates(account.tenant.id, scopes, [], 2)

    assert oldest_id == oldest.id
    assert oldest_conversation_id == account.conversation.id
    assert first_tied_id == hd(expected_tied_order)
    assert tied_conversation_id == other_conversation.id

    assert [
             %RetentionCandidate{
               message_id: remaining_tied_id,
               conversation_id: tied_conversation_id
             }
           ] =
             Messaging.retention_candidates(
               account.tenant.id,
               scopes,
               [oldest.id, hd(expected_tied_order)],
               10
             )

    assert remaining_tied_id == List.last(expected_tied_order)
    assert tied_conversation_id == other_conversation.id

    refute function_exported?(RetentionScope, :__schema__, 1)
    refute function_exported?(RetentionCandidate, :__schema__, 1)
  end

  test "retention candidates reject untyped scopes and non-positive limits" do
    tenant_id = Ecto.UUID.generate()

    valid_scope = %RetentionScope{
      conversation_id: Ecto.UUID.generate(),
      cutoff_at: DateTime.utc_now()
    }

    assert [] = Messaging.retention_candidates(tenant_id, [%{}], [], 10)
    assert [] = Messaging.retention_candidates("invalid-tenant", [valid_scope], [], 10)
    assert [] = Messaging.retention_candidates(tenant_id, [valid_scope], ["invalid-id"], 10)

    assert [] =
             Messaging.retention_candidates(
               tenant_id,
               [
                 %RetentionScope{
                   conversation_id: "invalid-conversation",
                   cutoff_at: DateTime.utc_now()
                 }
               ],
               [],
               10
             )

    assert [] =
             Messaging.retention_candidates(
               tenant_id,
               [valid_scope],
               [],
               0
             )
  end

  test "retention query groups a large shared-cutoff scope into bounded SQL" do
    tenant_id = Ecto.UUID.generate()
    cutoff_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    scopes =
      for _index <- 1..2_000 do
        %RetentionScope{
          conversation_id: Ecto.UUID.generate(),
          cutoff_at: cutoff_at
        }
      end

    parent = self()
    handler_id = {__MODULE__, :retention_query_shape, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler_id,
               [:comms_core, :repo, :query],
               fn _event, _measurements, metadata, test_pid ->
                 query = Map.get(metadata, :query, "")

                 if String.contains?(query, ~s(FROM "messages")) do
                   send(test_pid, {:retention_query_shape, query})
                 end
               end,
               parent
             )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert [] = Messaging.retention_candidates(tenant_id, scopes, [], 10)
    assert_receive {:retention_query_shape, query}

    assert String.contains?(query, "ANY(")

    placeholders =
      ~r/\$\d+/
      |> Regex.scan(query)
      |> List.flatten()
      |> Enum.uniq()

    assert length(placeholders) <= 6
  end

  test "governance impact fails closed for malformed UUIDs" do
    tenant_id = Ecto.UUID.generate()
    target_id = Ecto.UUID.generate()

    assert %GovernanceImpact{
             found?: false,
             message_ids: [],
             conversation_ids: [],
             user_ids: []
           } = Messaging.governance_impact("invalid-tenant", :message, target_id)

    assert %GovernanceImpact{
             found?: false,
             message_ids: [],
             conversation_ids: [],
             user_ids: []
           } = Messaging.governance_impact(tenant_id, :message, "invalid-target")
  end

  defp create_conversation!(subject, title) do
    assert {:ok, conversation} =
             Conversations.create_view(%{kind: :group, title: title}, subject)

    conversation
  end

  defp create_message!(account, conversation_id, client_message_id, inserted_at) do
    assert {:ok, message} =
             Messaging.accept_message(
               %{
                 tenant_id: account.tenant.id,
                 conversation_id: conversation_id,
                 sender_user_id: account.user.id,
                 sender_device_id: account.device.id,
                 client_message_id: client_message_id,
                 body: client_message_id
               },
               Fixtures.subject(account)
             )

    Message
    |> where([persisted], persisted.id == ^message.id)
    |> Repo.update_all(set: [inserted_at: inserted_at])

    message
  end
end
