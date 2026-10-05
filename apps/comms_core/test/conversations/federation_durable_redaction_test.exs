defmodule CommsCore.Conversations.FederationDurableRedactionTest do
  use ExUnit.Case, async: false
  alias CommsCore.{Accounts, Conversations, Repo, RuntimePorts}
  alias CommsCore.Accounts.MatrixProvisioningReceipt
  alias CommsCore.Conversations.Federation.Command
  alias CommsCore.Conversations.Federation.ProviderReceipt
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox
  import Ecto.Query
  @moduletag :integration
  @moduletag :concurrency

  defmodule IdentityProvider do
    @behaviour CommsCore.Accounts.MatrixProvisioningPort.Contract
    def execute(:provision, c),
      do: {:ok, %MatrixProvisioningReceipt{matrix_user_id: c.matrix_user_id}}

    def execute(:login, c),
      do:
        {:ok,
         %MatrixProvisioningReceipt{
           matrix_user_id: c.matrix_user_id,
           matrix_device_id: c.matrix_device_id,
           access_token: "durable-synthetic-access",
           refresh_token: "durable-synthetic-refresh",
           expires_in_ms: 180_000
         }}
  end

  defmodule BridgeProvider do
    @behaviour CommsCore.Conversations.Federation.ProviderPort
    def perform(request) do
      case request.operation do
        :create ->
          {:ok, %ProviderReceipt{operation: :create, room_id: "!durable:example.org"}}

        :send ->
          {:ok,
           %ProviderReceipt{operation: :send, event_id: "$durable-" <> request.transaction_id}}

        :redact ->
          parent = Application.fetch_env!(:comms_core, :federation_durable_test_parent)
          send(parent, {:native_redaction_boundary, self(), request})

          if request.effect_mode == :first_attempt do
            receive do
              :rollback_after_native_effect -> Repo.rollback(:synthetic_native_ack_lost)
            after
              3000 -> Repo.rollback(:synthetic_native_ack_lost)
            end
          else
            {:error, :federation_redaction_unconfirmed}
          end

        _ ->
          {:error, :federation_send_outcome_unconfirmed}
      end
    end
  end

  setup do
    # unboxed_run gives each worker/observer a real independent SQL transaction.
    settings = %{
      federation_enabled: true,
      federation_envelope_key: :crypto.strong_rand_bytes(32),
      federation_homeserver_origin: "https://matrix.example.org",
      federation_server_name: "example.org",
      federation_bridge_user: "@bridge:example.org",
      federation_provider_adapter: BridgeProvider,
      federation_durable_test_parent: self(),
      matrix_client_provisioning_enabled: true,
      matrix_provisioning_adapter: IdentityProvider,
      identity_secret_encryption_key: :crypto.strong_rand_bytes(32),
      matrix_identity_provider: %{
        issuer: "https://matrix.example.org",
        server_name: "example.org",
        control_user_id: "@control:example.org"
      }
    }

    previous = Enum.map(settings, fn {k, _} -> {k, Application.fetch_env(:comms_core, k)} end)
    Enum.each(settings, fn {k, v} -> Application.put_env(:comms_core, k, v) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {k, {:ok, v}} -> Application.put_env(:comms_core, k, v)
        {k, :error} -> Application.delete_env(:comms_core, k)
      end)
    end)

    {command, tenant_id} =
      Sandbox.unboxed_run(Repo, fn ->
        account = Fixtures.account_fixture()
        subject = Fixtures.step_up(account)
        assert {:ok, _} = Accounts.matrix_client_session(subject)

        assert {:ok, _} =
                 Conversations.put_federation_trust(
                   %{
                     domain: "remote.example.org",
                     residency: "Synthetic region",
                     cross_border_reason: "Reviewed durable redaction test",
                     enabled: true
                   },
                   subject
                 )

        assert {:ok, room} =
                 Conversations.create_federation_room(
                   account.conversation.id,
                   %{domain: "remote.example.org", plaintext_disclosure_accepted: true},
                   subject
                 )

        worker = RuntimePorts.job_worker!(:federation_command)
        create = Repo.get_by!(Command, room_id: room.id, kind: "create")
        assert :ok = worker.perform(%Oban.Job{args: %{"command_id" => create.id}})
        assert {:ok, active} = Conversations.federation_room(account.conversation.id, subject)

        assert {:ok, queued} =
                 Conversations.send_federation_message(
                   account.conversation.id,
                   %{
                     version: active.version,
                     body: "durable synthetic text",
                     idempotency_key: Ecto.UUID.generate()
                   },
                   subject
                 )

        assert {:ok, :ok} =
                 Conversations.deliver_federation_command(queued.id, worker, :recovery_only)

        assert {:ok, _} =
                 Conversations.federation_consent(
                   account.conversation.id,
                   %{version: active.version, accept: false},
                   subject
                 )

        {Repo.get_by!(Command, room_id: room.id, kind: "redact"), account.tenant.id}
      end)

    on_exit(fn ->
      # This cryptographically unique synthetic tenant is the only teardown
      # target. Marker proof is asserted before cleanup; the database is retained.
      Sandbox.unboxed_run(Repo, fn ->
        Repo.transaction(fn ->
          command_ids =
            Repo.all(from(c in Command, where: c.tenant_id == ^tenant_id, select: c.id))

          event_ids =
            Repo.all(
              from(e in CommsCore.Events.OutboxEvent,
                where: e.tenant_id == ^tenant_id,
                select: e.id
              )
            )

          for schema <- [
                CommsCore.Conversations.Federation.EventReceipt,
                Command,
                CommsCore.Conversations.Federation.Participant,
                CommsCore.Conversations.Federation.Room,
                CommsCore.Conversations.Federation.Trust,
                CommsCore.Accounts.MatrixClientSession,
                CommsCore.Accounts.MatrixIdentity
              ] do
            Repo.delete_all(from(r in schema, where: r.tenant_id == ^tenant_id))
          end

          Repo.delete_all(
            from(j in Oban.Job,
              where:
                fragment("?->>'tenant_id' = ?", j.args, ^tenant_id) or
                  fragment("?->>'event_id' = ANY(?::text[])", j.args, ^event_ids) or
                  fragment("?->>'command_id' = ANY(?::text[])", j.args, ^command_ids)
            )
          )

          Repo.delete_all(from(t in CommsCore.Administration.Tenant, where: t.id == ^tenant_id))
        end)
      end)
    end)

    %{command: command, worker: RuntimePorts.job_worker!(:federation_command)}
  end

  test "first marker is independently visible before native IO and survives worker process death",
       c do
    job = %Oban.Job{args: %{"command_id" => c.command.id}}
    worker = Task.async(fn -> Sandbox.unboxed_run(Repo, fn -> c.worker.perform(job) end) end)
    on_exit(fn -> reap(worker.pid) end)
    assert_receive {:native_redaction_boundary, first_pid, first}, 1000
    assert first.effect_mode == :first_attempt
    assert worker.pid == first_pid
    retained = Sandbox.unboxed_run(Repo, fn -> Repo.get!(Command, c.command.id) end)
    assert retained.status == "prepared" and retained.attempts == 1

    IO.puts(
      "Independent Federation marker proof: command=#{retained.id}; status=prepared; attempts=1; before_native_ack=true; cleanup=exact_synthetic_tenant"
    )

    assert Task.shutdown(worker, :brutal_kill) == nil

    restarted = Task.async(fn -> Sandbox.unboxed_run(Repo, fn -> c.worker.perform(job) end) end)
    on_exit(fn -> reap(restarted.pid) end)
    assert_receive {:native_redaction_boundary, next_pid, recovery}, 1000
    assert next_pid != first_pid
    assert recovery.transaction_id == first.transaction_id
    assert recovery.effect_mode == :recovery_only
    assert Task.await(restarted, 3000) == {:error, :federation_redaction_unconfirmed}
    retained = Sandbox.unboxed_run(Repo, fn -> Repo.get!(Command, c.command.id) end)
    assert retained.status == "uncertain" and retained.attempts == 2
    assert retained.payload_box
  end

  test "a recovery contender cannot grant the original worker another mutation opportunity", c do
    assert {:ok, :first_attempt} =
             Sandbox.unboxed_run(Repo, fn ->
               Conversations.prepare_federation_command(c.command.id, c.worker)
             end)

    recovery =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          c.worker.perform(%Oban.Job{args: %{"command_id" => c.command.id}})
        end)
      end)

    on_exit(fn -> reap(recovery.pid) end)

    assert_receive {:native_redaction_boundary, _, request}, 1000
    assert request.effect_mode == :recovery_only
    assert Task.await(recovery, 3000) == {:error, :federation_redaction_unconfirmed}

    assert {:ok, {:retry, :federation_redaction_unconfirmed}} =
             Sandbox.unboxed_run(Repo, fn ->
               Conversations.deliver_federation_command(c.command.id, c.worker, :first_attempt)
             end)

    assert_receive {:native_redaction_boundary, _, original}
    assert original.effect_mode == :recovery_only
    refute_received {:native_redaction_boundary, _, %{effect_mode: :first_attempt}}
    retained = Sandbox.unboxed_run(Repo, fn -> Repo.get!(Command, c.command.id) end)
    assert retained.status == "uncertain"
  end

  defp reap(pid) do
    reference = Process.monitor(pid)
    if Process.alive?(pid), do: Process.exit(pid, :kill)

    receive do
      {:DOWN, ^reference, :process, ^pid, _} -> :ok
    after
      3000 -> flunk("Synthetic worker was not reaped before fixture cleanup")
    end
  end
end
