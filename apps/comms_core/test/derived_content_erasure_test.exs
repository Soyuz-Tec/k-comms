defmodule CommsCore.DerivedContentErasureTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias CommsCore.{Governance, Integrations, Messaging, Outbox, Repo, RuntimePorts}
  alias CommsCore.Administration.Tenant
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Governance.DeletionRequest
  alias CommsCore.Integrations.WebhookDelivery
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :governance

  test "historical completed erasures are repaired in bounded idempotent batches" do
    fixture = fixture()

    unboxed(fn ->
      claim = claim_deletion(fixture)
      assert {:ok, %{request: %{evidence: evidence}}} = complete(claim)
      request = Repo.get!(DeletionRequest, claim.request_id)

      Repo.update_all(from(r in DeletionRequest, where: r.id == ^request.id),
        set: [evidence: Map.drop(evidence, [:derived_erasure_version, "derived_erasure_version"])]
      )

      Repo.update_all(from(e in OutboxEvent, where: e.id == ^fixture.event.id),
        set: [payload: %{"body" => "historical marker"}]
      )

      Repo.update_all(from(d in WebhookDelivery, where: d.id == ^fixture.delivery.id),
        set: [payload: %{"data" => %{"body" => "historical marker"}}]
      )

      assert {:error, :forbidden} = Governance.reconcile_completed_erasure(__MODULE__, 1)
      worker = RuntimePorts.job_worker!(:erasure_reconciler)

      assert {:ok, %{repaired: 1, has_more: true}} =
               Governance.reconcile_completed_erasure(worker, 1)

      assert Repo.get!(OutboxEvent, fixture.event.id).payload == %{"content_erased" => true}
      repaired = Repo.get!(DeletionRequest, request.id)
      assert repaired.evidence["derived_erasure_version"] == 1
      assert {:ok, _, 0} = DateTime.from_iso8601(repaired.evidence["derived_erasure_repaired_at"])

      assert {:ok, %{repaired: 0, has_more: false}} =
               Governance.reconcile_completed_erasure(worker, 1)
    end)
  end

  @tag :concurrency
  test "fanout paused before its transaction cannot recreate a delivery after erasure" do
    fixture = fixture()

    claim =
      unboxed(fn ->
        Repo.delete_all(from(d in WebhookDelivery, where: d.id == ^fixture.delivery.id))
        claim_deletion(fixture)
      end)

    parent = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:comms_core, :repo, :query],
      fn _, _, metadata, _ ->
        if String.contains?(metadata.query, ~s(JOIN "webhook_subscriptions")) do
          send(parent, {:fanout_discovered, self()})

          receive do
            :continue -> :ok
          after
            5_000 -> raise "fanout barrier timeout"
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    fanout =
      Task.async(fn -> unboxed(fn -> Integrations.enqueue_for_event(fixture.event) end) end)

    assert_receive {:fanout_discovered, pid}, 5_000
    unboxed(fn -> assert {:ok, _} = complete(claim) end)
    send(pid, :continue)
    assert :ok = Task.await(fanout, 5_000)
    unboxed(fn -> refute Repo.get_by(WebhookDelivery, outbox_event_id: fixture.event.id) end)
  end

  test "completed erasure removes event and delivery copies and stale fanout cannot restore them" do
    fixture = fixture()
    other = fixture()

    unboxed(fn ->
      claim = claim_deletion(fixture)
      assert {:ok, %{request: %{status: :completed}}} = complete(claim)
      assert Repo.get!(OutboxEvent, fixture.event.id).payload == %{"content_erased" => true}
      delivery = Repo.get!(WebhookDelivery, fixture.delivery.id)
      assert delivery.payload == %{"content_erased" => true}
      assert delivery.status == :failed
      assert {:error, :terminal_delivery} = Integrations.claim_delivery(delivery.id)

      assert {:error, :content_erased} =
               Integrations.replay_delivery(delivery.id, fixture.subject)

      assert :ok = Integrations.enqueue_for_event(fixture.event)

      assert Repo.aggregate(
               from(d in WebhookDelivery, where: d.outbox_event_id == ^fixture.event.id),
               :count
             ) == 1

      assert Repo.get!(OutboxEvent, other.event.id).payload["body"] == "private marker"

      assert Repo.get!(WebhookDelivery, other.delivery.id).payload["data"]["body"] ==
               "private marker"
    end)
  end

  test "a legal hold prevents erasure of derived copies" do
    fixture = fixture()

    unboxed(fn ->
      assert {:ok, _} =
               Governance.create_legal_hold(
                 %{name: "Preserve", reason: "Active investigation", scope_type: "tenant"},
                 fixture.subject
               )

      request = approve_deletion(fixture)

      assert {:error, :legal_hold_active} =
               Governance.claim_deletion_request(request.id, RuntimePorts.job_worker!(:deletion))

      assert Repo.get!(OutboxEvent, fixture.event.id).payload["body"] == "private marker"

      assert Repo.get!(WebhookDelivery, fixture.delivery.id).payload["data"]["body"] ==
               "private marker"
    end)
  end

  @tag :concurrency
  test "erasure waits for an in-flight dispatch and prevents a claimed request from sending afterwards" do
    fixture = fixture()

    {deletion, delivery_claim} =
      unboxed(fn ->
        deletion = claim_deletion(fixture)
        {:ok, delivery_claim} = Integrations.claim_delivery(fixture.delivery.id)
        {deletion, delivery_claim}
      end)

    parent = self()

    dispatch =
      Task.async(fn ->
        unboxed(fn ->
          Integrations.dispatch_delivery(delivery_claim, fn request ->
            assert request.body["data"]["body"] == "private marker"
            send(parent, {:dispatch_started, self()})

            receive do
              :finish_dispatch -> :ok
            after
              5_000 -> raise "dispatch barrier timed out"
            end
          end)
        end)
      end)

    assert_receive {:dispatch_started, sender}, 5_000
    erasure = Task.async(fn -> unboxed(fn -> complete(deletion) end) end)
    assert Task.yield(erasure, 100) == nil
    send(sender, :finish_dispatch)
    assert {:ok, :ok} = Task.await(dispatch, 5_000)
    assert {:ok, %{request: %{status: :completed}}} = Task.await(erasure, 5_000)

    unboxed(fn ->
      assert {:error, :stale_delivery_claim} =
               Integrations.dispatch_delivery(delivery_claim, fn _ ->
                 flunk("erased delivery reached provider")
               end)

      assert {:error, :stale_delivery_claim} = Integrations.record_delivery(delivery_claim, :ok)
    end)
  end

  test "abandoned claims do not block erasure and owner APIs require a transaction" do
    fixture = fixture()

    unboxed(fn ->
      assert {:error, :transaction_required} =
               Outbox.erase_message_content(fixture.account.tenant.id, [fixture.message.id])

      assert {:error, :transaction_required} =
               Integrations.erase_message_content(fixture.account.tenant.id, [fixture.event.id])

      {:ok, claim} = Integrations.claim_delivery(fixture.delivery.id)
      assert {:ok, _} = fixture |> claim_deletion() |> complete()

      assert {:error, :stale_delivery_claim} =
               Integrations.dispatch_delivery(claim, fn _ ->
                 flunk("abandoned claim sent erased content")
               end)
    end)
  end

  defp fixture do
    fixture =
      unboxed(fn ->
        account = Fixtures.account_fixture()
        subject = Fixtures.step_up(account)

        {:ok, message} =
          Messaging.accept_message(
            %{
              tenant_id: account.tenant.id,
              conversation_id: account.conversation.id,
              sender_user_id: account.user.id,
              sender_device_id: account.device.id,
              client_message_id: "erasure-source",
              body: "private marker"
            },
            subject
          )

        event =
          Repo.get_by!(OutboxEvent, aggregate_id: message.id, event_type: "message.created.v1")

        {:ok, event} =
          Outbox.fetch_for_publication(event.id, RuntimePorts.job_worker!(:outbox_publication))

        {:ok, _} =
          Integrations.create_endpoint(
            %{
              name: "Erasure sink",
              url: "https://hooks.example.test/events",
              event_types: ["message.created.v1"]
            },
            subject
          )

        :ok = Integrations.enqueue_for_event(event)
        delivery = Repo.get_by!(WebhookDelivery, outbox_event_id: event.id)
        %{account: account, subject: subject, message: message, event: event, delivery: delivery}
      end)

    on_exit(fn ->
      unboxed(fn ->
        tenant_id = fixture.account.tenant.id

        Repo.delete_all(
          from(job in Oban.Job, where: fragment("?->>'tenant_id' = ?", job.args, ^tenant_id))
        )

        Repo.delete_all(from(tenant in Tenant, where: tenant.id == ^tenant_id))
      end)
    end)

    fixture
  end

  defp claim_deletion(fixture) do
    request = approve_deletion(fixture)

    {:ok, claim} =
      Governance.claim_deletion_request(request.id, RuntimePorts.job_worker!(:deletion))

    claim
  end

  defp approve_deletion(fixture) do
    {:ok, %{request: request}} =
      Governance.create_deletion_request(
        %{target_type: "message", message_id: fixture.message.id, reason: "Verified erasure"},
        fixture.subject
      )

    {:ok, _} =
      Governance.transition_deletion_request(
        request.id,
        %{
          version: request.lock_version,
          status: "approved",
          transition_reason: "Approved erasure"
        },
        fixture.subject
      )

    request
  end

  defp complete(claim),
    do:
      Governance.complete_deletion_request(
        claim.request_id,
        claim.expected_version,
        %{deleted_object_count: 0},
        RuntimePorts.job_worker!(:deletion)
      )

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
