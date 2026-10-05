defmodule CommsCore.WhiteboardAuthorityRaceTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import CommsCore.MessagingFixtures

  alias CommsCore.{Accounts, AdmissionQuotas, Messaging, Repo, Whiteboards}
  alias CommsCore.Accounts.{Device, Session}
  alias CommsCore.Administration.Tenant
  alias CommsCore.Attachments.Attachment
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Whiteboards.{Asset, Operation, Snapshot, Version, Whiteboard}
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :concurrency

  setup do
    previous = Application.fetch_env(:comms_core, :whiteboard_snapshot_interval)
    Application.put_env(:comms_core, :whiteboard_snapshot_interval, 1)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:comms_core, :whiteboard_snapshot_interval, value)
        :error -> Application.delete_env(:comms_core, :whiteboard_snapshot_interval)
      end
    end)

    :ok
  end

  for operation <- [:append, :rename, :checkpoint, :restore, :export, :add_asset] do
    @operation operation

    @tag timeout: 30_000
    test "#{operation} refuses live Session expiry during its real board row wait" do
      fixture = fixture()
      before = board_state(fixture)
      parent = self()

      holder =
        actor(parent, :holder, fn ->
          Repo.transaction(fn ->
            Repo.one!(
              from(board in Whiteboard, where: board.id == ^fixture.board.id, lock: "FOR UPDATE")
            )

            send(parent, {:board_retained, self()})

            receive do
              :release_board -> :ok
            after
              12_000 -> raise "whiteboard authority holder timed out"
            end
          end)
        end)

      assert_receive {:holder_backend, holder_backend}, 5_000
      assert_receive {:board_retained, holder_pid}, 5_000
      expires_at = shorten_session(fixture)
      assert {:ok, _grant} = unboxed(fn -> Accounts.access_grant(fixture.subject) end)

      writer = actor(parent, :writer, fn -> invoke(@operation, fixture) end)
      assert_receive {:writer_backend, writer_backend}, 5_000
      {query, blockers} = wait_for_lock(writer_backend)
      assert String.contains?(query, ~s("whiteboards"))
      assert holder_backend in blockers
      wait_for_expiry(expires_at)
      send(holder_pid, :release_board)

      assert {:ok, :ok} = Task.await(holder, 5_000)
      assert {:error, :forbidden} = Task.await(writer, 5_000)
      assert board_state(fixture) == before
      unboxed(fn -> refute Repo.get!(Session, fixture.account.session.id).revoked_at end)
    end
  end

  for revocation <- [:session, :device] do
    @revocation revocation

    @tag timeout: 30_000
    test "append refuses actual #{revocation} revocation committed during its quota authority wait" do
      fixture = fixture()
      before = board_state(fixture)
      parent = self()

      holder =
        actor(parent, :holder, fn ->
          Repo.transaction(fn ->
            assert :ok = AdmissionQuotas.lock_tenant(fixture.account.tenant.id)
            send(parent, {:quota_retained, self()})

            receive do
              :release_quota -> :ok
            after
              12_000 -> raise "whiteboard quota holder timed out"
            end
          end)
        end)

      assert_receive {:holder_backend, holder_backend}, 5_000
      assert_receive {:quota_retained, holder_pid}, 5_000
      writer = actor(parent, :writer, fn -> invoke(:append, fixture) end)
      assert_receive {:writer_backend, writer_backend}, 5_000
      {query, blockers} = wait_for_lock(writer_backend)
      assert String.contains?(query, "pg_advisory_xact_lock")
      assert holder_backend in blockers

      result = unboxed(fn -> revoke(@revocation, fixture) end)

      if @revocation == :session,
        do: assert(result == :ok),
        else: assert(match?({:ok, _}, result))

      send(holder_pid, :release_quota)
      assert {:ok, :ok} = Task.await(holder, 5_000)
      assert {:error, :forbidden} = Task.await(writer, 5_000)
      assert board_state(fixture) == before

      unboxed(fn ->
        assert Repo.get!(Session, fixture.account.session.id).revoked_at

        if @revocation == :device,
          do: assert(Repo.get!(Device, fixture.account.device.id).revoked_at)
      end)
    end
  end

  defp fixture do
    fixture =
      unboxed(fn ->
        account = Fixtures.account_fixture()
        register_fixture_cleanup(account)
        subject = Fixtures.subject(account)

        assert {:ok, _, :created} =
                 Whiteboards.append_operation(
                   account.conversation.id,
                   %{
                     client_operation_id: "initial-authority-board-" <> account.user.id,
                     kind: "scene.update",
                     payload: %{
                       "elements" => [
                         %{
                           "id" => "original",
                           "type" => "rectangle",
                           "version" => 1,
                           "versionNonce" => 1
                         }
                       ]
                     }
                   },
                   subject
                 )

        board = Repo.get_by!(Whiteboard, conversation_id: account.conversation.id)

        assert {:ok, version} =
                 Whiteboards.checkpoint(
                   account.conversation.id,
                   %{label: "Current retained checkpoint", expected_sequence: board.sequence},
                   subject
                 )

        # Existing scanner fixture supplies immutable synthetic approved bytes.
        # Bind the actual raster claim to a message so add_asset's expiry case
        # has an otherwise valid resource, rather than an unavailable UUID.
        attachment = ready_attachment(subject, "a")

        Repo.update_all(from(row in Attachment, where: row.id == ^attachment.id),
          set: [content_type: "image/png"]
        )

        assert {:ok, _source} =
                 Messaging.accept_message(
                   message_attrs(account, "whiteboard-authority-image", [attachment.id]),
                   subject
                 )

        %{
          account: account,
          subject: subject,
          board: board,
          version: version,
          attachment_id: attachment.id
        }
      end)

    fixture
  end

  defp register_fixture_cleanup(account) do
    on_exit(fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
          tenant_id = account.tenant.id

          event_ids =
            Repo.all(
              from(event in OutboxEvent, where: event.tenant_id == ^tenant_id, select: event.id)
            )

          Repo.delete_all(
            from(job in Oban.Job,
              where:
                fragment("?->>'tenant_id' = ?", job.args, ^tenant_id) or
                  fragment("?->>'event_id' = ANY(?::text[])", job.args, ^event_ids)
            )
          )

          Repo.delete_all(from(tenant in Tenant, where: tenant.id == ^tenant_id))
        end)
      end)
    end)
  end

  defp invoke(:append, fixture),
    do:
      Whiteboards.append_operation(
        fixture.account.conversation.id,
        %{
          client_operation_id: "late-authority-operation",
          kind: "scene.update",
          payload: %{
            "elements" => [
              %{
                "id" => "late-authority-element",
                "type" => "rectangle",
                "version" => 1,
                "versionNonce" => 2
              }
            ]
          }
        },
        fixture.subject
      )

  defp invoke(:rename, fixture),
    do:
      Whiteboards.rename(
        fixture.account.conversation.id,
        %{title: "Expired private title", expected_version: fixture.board.library_version},
        fixture.subject
      )

  defp invoke(:checkpoint, fixture),
    do:
      Whiteboards.checkpoint(
        fixture.account.conversation.id,
        %{label: "Expired private checkpoint", expected_sequence: fixture.board.sequence},
        fixture.subject
      )

  defp invoke(:restore, fixture),
    do:
      Whiteboards.restore(
        fixture.account.conversation.id,
        fixture.version.id,
        %{expected_sequence: fixture.board.sequence},
        fixture.subject
      )

  defp invoke(:export, fixture),
    do: Whiteboards.export(fixture.account.conversation.id, fixture.subject)

  defp invoke(:add_asset, fixture),
    do:
      Whiteboards.add_asset(
        fixture.account.conversation.id,
        fixture.attachment_id,
        fixture.subject
      )

  defp revoke(:session, fixture),
    do:
      Accounts.revoke_own_session_command(
        fixture.account.session.id,
        fixture.subject
      )

  defp revoke(:device, fixture),
    do:
      Accounts.revoke_device_command(
        fixture.account.device.id,
        fixture.subject
      )

  defp board_state(fixture),
    do:
      unboxed(fn ->
        board_id = fixture.board.id

        %{
          board: Repo.get!(Whiteboard, board_id),
          operations:
            Repo.all(
              from(row in Operation,
                where: row.whiteboard_id == ^board_id,
                order_by: [asc: row.sequence]
              )
            ),
          versions:
            Repo.all(
              from(row in Version,
                where: row.whiteboard_id == ^board_id,
                order_by: [asc: row.id]
              )
            ),
          assets:
            Repo.all(
              from(row in Asset,
                where: row.whiteboard_id == ^board_id,
                order_by: [asc: row.id]
              )
            ),
          snapshots:
            Repo.all(
              from(row in Snapshot,
                where: row.whiteboard_id == ^board_id,
                order_by: [asc: row.id]
              )
            )
        }
      end)

  defp shorten_session(fixture),
    do:
      unboxed(fn ->
        expiry = DateTime.add(DateTime.utc_now(), 3, :second)

        Repo.get!(Session, fixture.account.session.id)
        |> Ecto.Changeset.change(expires_at: expiry)
        |> Repo.update!()

        expiry
      end)

  defp actor(parent, label, operation) do
    task =
      Task.async(fn ->
        unboxed(fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows
          send(parent, {String.to_atom("#{label}_backend"), backend})
          operation.()
        end)
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    task
  end

  defp wait_for_lock(backend, attempts \\ 300)

  defp wait_for_lock(_backend, 0),
    do: flunk("whiteboard operation did not reach an actual row/advisory wait")

  defp wait_for_lock(backend, attempts) do
    case unboxed(fn ->
           Repo.query!(
             "SELECT query, pg_blocking_pids(pid) FROM pg_stat_activity WHERE pid = $1 AND wait_event_type = 'Lock' AND cardinality(pg_blocking_pids(pid)) > 0",
             [backend]
           ).rows
         end) do
      [[query, blockers]] ->
        {query, blockers}

      [] ->
        Process.sleep(10)
        wait_for_lock(backend, attempts - 1)
    end
  end

  defp wait_for_expiry(expiry) do
    if DateTime.compare(DateTime.utc_now(), expiry) != :gt do
      Process.sleep(10)
      wait_for_expiry(expiry)
    end
  end

  defp unboxed(operation), do: Sandbox.unboxed_run(Repo, operation)
end
