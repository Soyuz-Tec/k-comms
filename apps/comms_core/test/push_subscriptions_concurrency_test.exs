defmodule CommsCore.Notifications.PushSubscriptionsConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias CommsCore.Accounts.{Device, Tenant}
  alias CommsCore.Audit
  alias CommsCore.Notifications.{PushSubscription, PushSubscriptions}
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @repo_query_event [:comms_core, :repo, :query]
  @p256dh "BIdD6B2jZb5v7fwxbXdnpkOpJrsegpqJbZPPoWb3dI6m5jpkSTB_ZekUrAdKVXR4f_s5nU89TSZlDOxcTHJxAFo"
  @auth "AAECAwQFBgcICQoLDA0ODw"

  test "registration re-reads a revoked endpoint after its row lock is released" do
    account = unboxed(&Fixtures.account_fixture/0)
    register_cleanup(account.tenant.id)
    subject = Fixtures.subject(account)
    attrs = subscription_attrs("https://push.example.test/send/revoke-registration-race")

    assert {:ok, %{subscription: original}} =
             unboxed(fn -> PushSubscriptions.register(attrs, subject) end)

    rotated_attrs =
      put_in(
        attrs,
        [:keys, :auth],
        Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      )

    parent = self()
    release_ref = make_ref()
    handler_id = {__MODULE__, :revoke_registration_race, make_ref()}
    registration_handler_id = {__MODULE__, :registration_lock_order, make_ref()}
    on_exit(fn -> :telemetry.detach(handler_id) end)
    on_exit(fn -> :telemetry.detach(registration_handler_id) end)

    revoke_task =
      Task.async(fn ->
        unboxed(fn ->
          attach_query_barrier(
            handler_id,
            parent,
            release_ref,
            :revoke_row_locked,
            &push_subscription_row_lock_query?/1
          )

          PushSubscriptions.revoke(original.id, subject)
        end)
      end)

    revoke_pid = revoke_task.pid
    assert_receive {:revoke_row_locked, ^revoke_pid}, 5_000

    registration_task =
      Task.async(fn ->
        unboxed(fn ->
          backend_pid = database_backend_pid()
          send(parent, {:registration_connection_ready, self(), backend_pid})

          attach_registration_lock_recorder(registration_handler_id, parent)

          try do
            PushSubscriptions.register(rotated_attrs, subject)
          after
            :telemetry.detach(registration_handler_id)
          end
        end)
      end)

    registration_pid = registration_task.pid

    assert_receive {:registration_connection_ready, ^registration_pid, registration_backend_pid},
                   5_000

    assert_registration_waits_for_endpoint_row(registration_backend_pid)
    send(revoke_pid, {:release_query_barrier, release_ref})

    assert {:ok, revoked} = Task.await(revoke_task, 15_000)
    assert revoked.status == :revoked

    assert {:ok, %{subscription: reactivated, replayed: false}} =
             Task.await(registration_task, 15_000)

    assert collect_registration_lock_steps(registration_pid, []) == [
             :capacity_advisory,
             :endpoint_advisory,
             :identity_user,
             :identity_device,
             :endpoint_row
           ]

    assert reactivated.id == original.id
    assert reactivated.version == original.version + 1
    assert reactivated.status == :active

    persisted = unboxed(fn -> Repo.get!(PushSubscription, original.id) end)
    assert persisted.version == reactivated.version
    assert persisted.status == :active

    actions =
      unboxed(fn ->
        Audit.list(%{
          tenant_id: account.tenant.id,
          resource_type: "push_subscription",
          resource_id: original.id
        })
      end)
      |> Enum.map(& &1.action)

    assert "push_subscription.revoked" in actions
    assert "push_subscription.reactivated" in actions
    refute "push_subscription.rotated" in actions
  end

  test "the second materialization gate observes identity revocation before returning a destination" do
    account = unboxed(&Fixtures.account_fixture/0)
    register_cleanup(account.tenant.id)
    subject = Fixtures.subject(account)

    assert {:ok, %{subscription: subscription}} =
             unboxed(fn ->
               PushSubscriptions.register(
                 subscription_attrs(
                   "https://push.example.test/send/materialization-identity-race"
                 ),
                 subject
               )
             end)

    parent = self()
    release_ref = make_ref()
    handler_id = {__MODULE__, :materialization_identity_race, make_ref()}
    on_exit(fn -> :telemetry.detach(handler_id) end)

    materialization_task =
      Task.async(fn ->
        unboxed(fn ->
          backend_pid = database_backend_pid()
          send(parent, {:materialization_connection_ready, self(), backend_pid})

          attach_query_barrier(
            handler_id,
            parent,
            release_ref,
            :materialization_generation_updated,
            &materialization_generation_update_query?/1
          )

          PushSubscriptions.materialize_destination(
            subscription.id,
            subscription.version,
            subscription.tenant_id
          )
        end)
      end)

    materialization_pid = materialization_task.pid

    assert_receive {:materialization_connection_ready, ^materialization_pid,
                    materialization_backend_pid},
                   5_000

    assert_receive {:materialization_generation_updated, ^materialization_pid}, 5_000

    {identity_backend_pid, {1, _}} =
      unboxed(fn ->
        backend_pid = database_backend_pid()

        result =
          Device
          |> where([device], device.id == ^account.device.id)
          |> Repo.update_all(
            set: [
              revoked_at: now(),
              updated_at: now()
            ]
          )

        {backend_pid, result}
      end)

    refute identity_backend_pid == materialization_backend_pid
    send(materialization_pid, {:release_query_barrier, release_ref})

    assert {:error, :push_subscription_stale} =
             Task.await(materialization_task, 15_000)

    persisted = unboxed(fn -> Repo.get!(PushSubscription, subscription.id) end)
    assert persisted.status == :active
    assert is_nil(persisted.last_materialized_at)
  end

  defp attach_query_barrier(handler_id, parent, release_ref, message, matcher) do
    target_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @repo_query_event,
        fn _event, _measurements, metadata, config ->
          if self() == config.target_pid and config.matcher.(metadata) do
            :telemetry.detach(config.handler_id)
            send(config.parent, {config.message, self()})

            receive do
              {:release_query_barrier, ^release_ref} -> :ok
            after
              5_000 -> raise "push subscription query barrier timed out"
            end
          end
        end,
        %{
          handler_id: handler_id,
          matcher: matcher,
          message: message,
          parent: parent,
          target_pid: target_pid
        }
      )
  end

  defp push_subscription_row_lock_query?(%{query: query}) when is_binary(query) do
    String.contains?(query, ~s(FROM "push_subscriptions")) and
      String.contains?(query, "FOR UPDATE")
  end

  defp push_subscription_row_lock_query?(_metadata), do: false

  defp attach_registration_lock_recorder(handler_id, parent) do
    target_pid = self()
    Process.put({handler_id, :advisory_count}, 0)

    :ok =
      :telemetry.attach(
        handler_id,
        @repo_query_event,
        fn _event, _measurements, metadata, config ->
          if self() == config.target_pid do
            case registration_lock_step(metadata, config.handler_id) do
              nil -> :ok
              step -> send(config.parent, {:registration_lock_step, self(), step})
            end
          end
        end,
        %{handler_id: handler_id, parent: parent, target_pid: target_pid}
      )
  end

  defp registration_lock_step(%{query: query}, handler_id) when is_binary(query) do
    cond do
      String.contains?(query, "pg_advisory_xact_lock") ->
        advisory_count = Process.get({handler_id, :advisory_count}, 0)
        Process.put({handler_id, :advisory_count}, advisory_count + 1)

        if advisory_count == 0, do: :capacity_advisory, else: :endpoint_advisory

      String.contains?(query, ~s(FROM "users")) and String.contains?(query, "FOR SHARE") ->
        :identity_user

      String.contains?(query, ~s(FROM "devices")) and String.contains?(query, "FOR SHARE") ->
        :identity_device

      String.contains?(query, ~s(FROM "push_subscriptions")) and
          String.contains?(query, "FOR UPDATE") ->
        :endpoint_row

      true ->
        nil
    end
  end

  defp registration_lock_step(_metadata, _handler_id), do: nil

  defp materialization_generation_update_query?(%{query: query}) when is_binary(query) do
    String.contains?(query, ~s(UPDATE "push_subscriptions")) and
      String.contains?(query, "last_materialized_at")
  end

  defp materialization_generation_update_query?(_metadata), do: false

  defp assert_registration_waits_for_endpoint_row(backend_pid) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    await_registration_row_lock(backend_pid, deadline)
  end

  defp collect_registration_lock_steps(task_pid, steps) do
    receive do
      {:registration_lock_step, ^task_pid, step} ->
        collect_registration_lock_steps(task_pid, [step | steps])
    after
      0 -> Enum.reverse(steps)
    end
  end

  defp await_registration_row_lock(backend_pid, deadline) do
    activity =
      unboxed(fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT wait_event_type, query
          FROM pg_stat_activity
          WHERE pid = $1
          """,
          [backend_pid]
        )
      end)

    case activity.rows do
      [["Lock", query]] when is_binary(query) ->
        assert String.contains?(query, ~s(FROM "push_subscriptions"))
        assert String.contains?(query, "FOR UPDATE")

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("registration did not wait for the push subscription row lock")
        else
          Process.sleep(10)
          await_registration_row_lock(backend_pid, deadline)
        end
    end
  end

  defp register_cleanup(tenant_id) do
    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(
          from(job in Oban.Job,
            where: fragment("?->>'tenant_id' = ?", job.args, ^tenant_id)
          )
        )

        Repo.delete_all(from(tenant in Tenant, where: tenant.id == ^tenant_id))
      end)
    end)
  end

  defp subscription_attrs(endpoint) do
    %{
      endpoint: endpoint,
      expiration_time: nil,
      keys: %{p256dh: @p256dh, auth: @auth}
    }
  end

  defp database_backend_pid do
    %{rows: [[backend_pid]]} =
      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", [])

    backend_pid
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
