defmodule CommsCore.Administration.TenantSettingsCallLockOrderTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias CommsCore.{Accounts, Administration, Repo, Telephony}
  alias CommsCore.Accounts.Session
  alias CommsCore.Administration.Tenant
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Telephony.Call
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :concurrency
  @moduletag :call

  setup do
    {account, settings_subject, phone_subject, call} =
      unboxed(fn ->
        account = Fixtures.account_fixture()
        settings_subject = Fixtures.step_up(account)
        suffix = account.tenant.slug |> String.split("-") |> List.last()

        {:ok, authentication} =
          Accounts.authenticate_view(
            account.tenant.slug,
            account.user.email,
            "correct-horse-battery-#{suffix}",
            %{name: "Revoked phone browser", platform: "test"}
          )

        {:ok, context} = Accounts.access_context(authentication.session_id)
        phone_subject = context.subject

        number_suffix =
          System.unique_integer([:positive])
          |> rem(100_000)
          |> Integer.to_string()
          |> String.pad_leading(5, "0")

        {:ok, _} =
          Telephony.provision(
            %{
              phone_number: "+14155" <> number_suffix,
              extension: "101",
              user_id: account.user.id,
              inbound_trunk_id: "ST_settings_lock_in",
              outbound_trunk_id: "ST_settings_lock_out",
              reason: "Synthetic answered-call settings lock fixture"
            },
            settings_subject
          )

        {:ok, view, :created} =
          Telephony.start_outbound(
            %{destination: "+14155550200", idempotency_key: "settings-lock-order"},
            phone_subject
          )

        call =
          Repo.get!(Call, view.id)
          |> Call.changeset(%{
            status: :answered,
            answered_at: DateTime.utc_now(),
            dispatch_status: :started,
            provider_call_id: "SC_settings_lock_" <> view.id
          })
          |> Repo.update!()

        {account, settings_subject, phone_subject, call}
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
          event_ids =
            Repo.all(
              from(event in OutboxEvent,
                where: event.tenant_id == ^account.tenant.id,
                select: event.id
              )
            )

          Repo.delete_all(
            from(job in Oban.Job,
              where: fragment("?->>'tenant_id' = ?", job.args, ^account.tenant.id)
            )
          )

          Repo.delete_all(
            from(job in Oban.Job,
              where: fragment("?->>'call_id' = ?", job.args, ^call.id)
            )
          )

          Repo.delete_all(
            from(job in Oban.Job,
              where: fragment("?->>'event_id'", job.args) in ^event_ids
            )
          )

          Repo.delete_all(from(tenant in Tenant, where: tenant.id == ^account.tenant.id))
        end)
      end)
    end)

    %{
      account: account,
      settings_subject: settings_subject,
      phone_subject: phone_subject,
      call: call
    }
  end

  test "audio disable and answered-call session revocation commit through the outbox Tenant FK",
       context do
    %{
      account: account,
      settings_subject: settings_subject,
      phone_subject: phone_subject,
      call: call
    } = context

    parent = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:comms_core, :repo, :query],
        fn _, _, metadata, _ ->
          if Process.get(:settings_lock_actor) == :revoker and
               String.contains?(metadata.query, ~s(FROM "telephony_calls")) and
               String.contains?(metadata.query, "FOR UPDATE") do
            send(parent, {:answered_call_locked, self()})

            receive do
              :publish_revocation -> :ok
            after
              10_000 -> raise "answered-call revocation barrier timed out"
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    revoker =
      Task.async(fn ->
        unboxed(fn ->
          Process.put(:settings_lock_actor, :revoker)
          send(parent, {:revoker_backend, backend_pid()})
          Accounts.revoke_own_session_command(phone_subject.session_id, phone_subject)
        end)
      end)

    assert_receive {:revoker_backend, revoker_backend}, 5_000
    assert_receive {:answered_call_locked, revoker_pid}, 5_000

    settings =
      Task.async(fn ->
        unboxed(fn ->
          send(parent, {:settings_backend, backend_pid()})

          Administration.update_tenant_settings(
            %{version: 1, name: "Updated non-key tenant name", allow_audio_calls: false},
            settings_subject
          )
        end)
      end)

    assert_receive {:settings_backend, settings_backend}, 5_000
    assert_waiting(settings_backend, "telephony_calls", revoker_backend)
    send(revoker_pid, :publish_revocation)

    assert :ok = Task.await(revoker, 5_000)
    assert {:ok, result} = Task.await(settings, 5_000)
    assert result.settings.allow_audio_calls == false
    assert result.tenant.name == "Updated non-key tenant name"

    unboxed(fn ->
      stored = Repo.get!(Call, call.id)
      assert stored.status == :ended
      assert stored.ended_at
      assert stored.end_reason
      assert stored.provider_call_id == call.provider_call_id
      refute stored.cleanup_claimed_at
      refute stored.cleanup_completed_at
      assert Repo.get!(Session, phone_subject.session_id).revoked_at
      refute Repo.get!(Session, settings_subject.session_id).revoked_at

      assert Repo.aggregate(
               from(event in OutboxEvent,
                 where:
                   event.tenant_id == ^account.tenant.id and event.aggregate_id == ^call.id and
                     event.event_type == "telephony.call.updated" and
                     fragment("?->>'status' = 'ended'", event.payload)
               ),
               :count
             ) == 1

      assert Repo.exists?(
               from(job in Oban.Job,
                 where:
                   job.worker == "CommsWorkers.TelephonyCleanupWorker" and
                     job.state == "available" and
                     job.attempt == 0 and fragment("?->>'call_id' = ?", job.args, ^call.id)
               )
             )
    end)
  end

  test "settings still exclude current call-policy SHARE readers", context do
    %{account: account, settings_subject: subject} = context
    parent = self()

    policy_reader =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            assert {:ok, policy} = Administration.lock_call_policy(account.tenant.id)
            assert policy.allow_audio_calls
            send(parent, {:policy_held, self(), backend_pid()})

            receive do
              :finish_policy_read -> :ok
            after
              10_000 -> raise "call-policy read barrier timed out"
            end
          end)
        end)
      end)

    assert_receive {:policy_held, reader_pid, reader_backend}, 5_000

    settings =
      Task.async(fn ->
        unboxed(fn ->
          send(parent, {:settings_backend, backend_pid()})
          Administration.update_tenant_settings(%{version: 1, allow_audio_calls: false}, subject)
        end)
      end)

    assert_receive {:settings_backend, settings_backend}, 5_000
    assert_waiting(settings_backend, "tenants", reader_backend)

    assert {:ok, current} = unboxed(fn -> Administration.get_tenant_settings(subject) end)
    assert current.settings.allow_audio_calls

    send(reader_pid, :finish_policy_read)
    assert {:ok, :ok} = Task.await(policy_reader, 5_000)
    assert {:ok, result} = Task.await(settings, 5_000)
    refute result.settings.allow_audio_calls
  end

  defp assert_waiting(pid, table, blocker),
    do: await_row_lock(pid, table, blocker, System.monotonic_time(:millisecond) + 5_000)

  defp await_row_lock(pid, table, blocker, deadline) do
    activity =
      unboxed(fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT wait_event_type, query, pg_blocking_pids(pid) FROM pg_stat_activity WHERE pid = $1",
          [pid]
        )
      end)

    case activity.rows do
      [["Lock", query, blockers]] ->
        assert String.contains?(query, ~s(FROM "#{table}"))
        assert String.contains?(query, "FOR ")
        assert blocker in blockers

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("settings did not wait for its exact #{table} blocker")
        else
          Process.sleep(10)
          await_row_lock(pid, table, blocker, deadline)
        end
    end
  end

  defp backend_pid do
    %{rows: [[pid]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    pid
  end

  defp unboxed(operation), do: Sandbox.unboxed_run(Repo, operation)
end
