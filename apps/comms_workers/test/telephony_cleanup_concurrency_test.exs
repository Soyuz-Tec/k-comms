defmodule CommsWorkers.TelephonyCleanupConcurrencyTest.BarrierProvider do
  @behaviour CommsCore.Telephony.ProviderControlPort.Contract

  def capabilities(), do: %{}
  def authorize_destination(_), do: :ok
  def verify_event(_, _), do: {:error, :invalid_provider_webhook}
  def execute_control(_), do: {:error, :telephony_control_unsupported}
  def bound_call_status(_), do: {:error, :telephony_provider_unavailable}

  def cleanup_call(command) do
    parent = Process.get(:cleanup_test_parent) || raise "cleanup parent is required"
    send(parent, {:cleanup_effect_locked, self(), command, CommsCore.Repo.in_transaction?()})

    receive do
      :continue_cleanup -> :ok
    after
      5_000 -> raise "cleanup provider barrier timed out"
    end
  end
end

defmodule CommsWorkers.TelephonyCleanupConcurrencyTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :call
  @moduletag :concurrency

  import Ecto.Query
  alias CommsCore.{Repo, Telephony}
  alias CommsCore.Administration.Tenant
  alias CommsCore.Telephony.{Call, Number, ProviderCommand}
  alias CommsTestSupport.Fixtures
  alias CommsWorkers.TelephonyCleanupWorker
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    previous = Application.fetch_env(:comms_core, :telephony_control_adapter)

    Application.put_env(
      :comms_core,
      :telephony_control_adapter,
      __MODULE__.BarrierProvider
    )

    {account, call} = unboxed(&terminal_fixture/0)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(
          from(job in Oban.Job,
            where:
              fragment("?->>'call_id'", job.args) == ^call.id or
                fragment("?->>'tenant_id'", job.args) == ^account.tenant.id
          )
        )

        Repo.delete_all(from(tenant in Tenant, where: tenant.id == ^account.tenant.id))
      end)

      case previous do
        {:ok, value} -> Application.put_env(:comms_core, :telephony_control_adapter, value)
        :error -> Application.delete_env(:comms_core, :telephony_control_adapter)
      end
    end)

    %{call: call}
  end

  test "the current call row stays locked across the actual provider cleanup effect", %{
    call: call
  } do
    assert {:ok, %ProviderCommand{}} =
             unboxed(fn -> Telephony.claim_cleanup(call.id, TelephonyCleanupWorker) end)

    parent = self()

    cleanup =
      Task.async(fn ->
        unboxed(fn ->
          Process.put(:cleanup_test_parent, parent)
          Telephony.complete_cleanup(call.id, :execute, TelephonyCleanupWorker)
        end)
      end)

    on_exit(fn -> if Process.alive?(cleanup.pid), do: Process.exit(cleanup.pid, :kill) end)

    assert_receive {:cleanup_effect_locked, effect_pid, %ProviderCommand{} = command, true},
                   5_000

    assert command.call_id == call.id
    assert command.status == :ended
    assert command.pbx_state == call.pbx_state
    assert is_nil(unboxed(fn -> Repo.get!(Call, call.id).cleanup_completed_at end))

    binding = Map.put(call.pbx_state, "consult", "replacement-consult-" <> call.id)

    updater =
      Task.async(fn ->
        unboxed(fn ->
          send(parent, {:updater_started, self()})

          from(current in Call, where: current.id == ^call.id)
          |> Repo.update_all(set: [pbx_state: binding])
        end)
      end)

    on_exit(fn -> if Process.alive?(updater.pid), do: Process.exit(updater.pid, :kill) end)
    assert_receive {:updater_started, _}, 5_000
    assert Task.yield(updater, 100) == nil

    send(effect_pid, :continue_cleanup)
    assert :ok = Task.await(cleanup, 5_000)
    assert {1, nil} = Task.await(updater, 5_000)

    persisted = unboxed(fn -> Repo.get!(Call, call.id) end)
    assert persisted.cleanup_completed_at
    assert persisted.pbx_state == binding
  end

  defp terminal_fixture do
    account = Fixtures.account_fixture()
    suffix = System.unique_integer([:positive, :monotonic]) |> Integer.to_string()
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    number =
      %Number{}
      |> Number.changeset(%{
        tenant_id: account.tenant.id,
        user_id: account.user.id,
        phone_number: "+1555" <> String.pad_leading(suffix, 7, "0"),
        extension: "101",
        inbound_trunk_id: "ST_cleanup_concurrency_inbound",
        outbound_trunk_id: "ST_cleanup_concurrency_outbound"
      })
      |> Repo.insert!()

    id = Ecto.UUID.generate()

    call =
      %Call{id: id}
      |> Call.changeset(%{
        tenant_id: account.tenant.id,
        number_id: number.id,
        user_id: account.user.id,
        direction: :outbound,
        status: :ended,
        from_number: number.phone_number,
        to_number: "+15555550199",
        extension: number.extension,
        inbound_trunk_id: number.inbound_trunk_id,
        outbound_trunk_id: number.outbound_trunk_id,
        provider_room: "cleanup-concurrency-" <> id,
        provider_identity: "sip-cleanup-concurrency-" <> id,
        dispatch_status: :started,
        control_state: "consulting",
        pbx_state: %{
          "external" => "external-" <> id,
          "app" => "app-" <> id,
          "mixing" => "mixing-" <> id,
          "holding" => "holding-" <> id,
          "consult" => "consult-" <> id,
          "recording" => "recording-" <> id
        },
        started_at: DateTime.add(timestamp, -30, :second),
        answered_at: DateTime.add(timestamp, -20, :second),
        ended_at: timestamp,
        end_reason: "synthetic_concurrency_cleanup",
        expires_at: DateTime.add(timestamp, 45, :second)
      })
      |> Repo.insert!()

    {account, call}
  end

  defp unboxed(function), do: Sandbox.unboxed_run(Repo, function)
end
