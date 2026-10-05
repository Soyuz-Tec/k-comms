defmodule CommsCore.PrivateRooms.RetainedAuthorityRaceTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias CommsCore.{Accounts, Conversations, Messaging, Repo}
  alias CommsCore.Accounts.MatrixProvisioningReceipt
  alias CommsCore.Conversations.PrivateRoomControlReceipt
  alias CommsCore.Messaging.PrivateEventReceipt
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox
  @moduletag :integration
  @moduletag :concurrency

  defmodule IdentityProvider do
    @behaviour CommsCore.Accounts.MatrixProvisioningPort.Contract
    def execute(:provision, c),
      do: {:ok, %MatrixProvisioningReceipt{matrix_user_id: c.matrix_user_id}}

    def execute(action, c) when action in [:login, :refresh] do
      case Application.get_env(:comms_core, :private_identity_login_barrier) do
        {user_id, parent} when c.user_id == user_id ->
          send(parent, {:native_login_issued, self()})

          receive do
            :release_login -> :ok
          after
            10_000 -> raise "identity issuance barrier expired"
          end

        _ ->
          :ok
      end

      {:ok,
       %MatrixProvisioningReceipt{
         matrix_user_id: c.matrix_user_id,
         matrix_device_id: c.matrix_device_id,
         access_token: "race-auth-only",
         refresh_token: "race-refresh-only",
         expires_in_ms: 180_000
       }}
    end

    def execute(:revoke, c),
      do:
        {:ok,
         %MatrixProvisioningReceipt{
           matrix_user_id: c.matrix_user_id,
           matrix_device_id: c.matrix_device_id,
           revoked?: true
         }}
  end

  defmodule RoomProvider do
    @behaviour CommsCore.Conversations.PrivateRoomControlPort.Contract
    def execute(:provision, c),
      do:
        {:ok,
         %PrivateRoomControlReceipt{matrix_room_id: "!" <> c.conversation_id <> ":example.test"}}
  end

  defmodule EventProvider do
    @behaviour CommsCore.Messaging.PrivateEventPort.Contract
    def send_encrypted(c) do
      parent = Application.fetch_env!(:comms_core, :private_test_barrier_parent)
      send(parent, {:native_send_retained, self()})

      receive do
        :release_native -> :ok
      after
        10_000 -> raise "native test barrier expired"
      end

      {:ok,
       %PrivateEventReceipt{
         matrix_room_id: c.grant.matrix_room_id,
         matrix_sender: c.grant.matrix_user_id,
         matrix_event_id: "$race",
         content: c.content
       }}
    end
  end

  setup do
    settings = %{
      matrix_client_provisioning_enabled: true,
      private_rooms_enabled: true,
      matrix_provisioning_adapter: IdentityProvider,
      private_room_control_adapter: RoomProvider,
      private_event_adapter: EventProvider,
      identity_secret_encryption_key: :crypto.strong_rand_bytes(32),
      private_test_barrier_parent: self(),
      private_identity_login_barrier: nil,
      matrix_identity_provider: %{
        issuer: "https://matrix.example.test",
        server_name: "example.test",
        control_user_id: "@control:example.test"
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

    {account, room, peer} =
      unboxed(fn ->
        account =
          Fixtures.account_fixture(%{
            tenant_slug: "private-race-" <> String.replace(Ecto.UUID.generate(), "-", "")
          })

        %{user: peer} = Fixtures.user_fixture(account)

        peer_subject =
          CommsCore.TrustGovernanceTestSupport.authenticated_subject(
            account,
            peer,
            "Race private peer"
          )

        {:ok, _} = Accounts.matrix_client_session(Fixtures.subject(account))
        {:ok, _} = Accounts.matrix_client_session(peer_subject)

        {:ok, room} =
          Conversations.create_private_room(
            %{id: Ecto.UUID.generate(), title: "Retained native effect", member_ids: [peer.id]},
            Fixtures.subject(account)
          )

        {account, room, peer}
      end)

    # Cleanup is confined to this newly generated disposable test tenant; no
    # initial retained source/data or migration evidence is removed.
    on_exit(fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
          tenant = account.tenant.id

          Repo.delete_all(
            from(e in CommsCore.Messaging.PrivateEvent, where: e.tenant_id == ^tenant)
          )

          Repo.delete_all(
            from(r in CommsCore.Conversations.PrivateRoom, where: r.tenant_id == ^tenant)
          )

          Repo.delete_all(
            from(s in CommsCore.Accounts.MatrixClientSession, where: s.tenant_id == ^tenant)
          )

          Repo.delete_all(
            from(i in CommsCore.Accounts.MatrixIdentity, where: i.tenant_id == ^tenant)
          )

          event_ids =
            Repo.all(
              from(e in CommsCore.Events.OutboxEvent, where: e.tenant_id == ^tenant, select: e.id)
            )

          Repo.delete_all(
            from(j in Oban.Job,
              where:
                fragment("?->>'tenant_id' = ?", j.args, ^tenant) or
                  fragment("?->>'event_id' = ANY(?::text[])", j.args, ^event_ids)
            )
          )

          Repo.delete_all(from(t in CommsCore.Administration.Tenant, where: t.id == ^tenant))
        end)
      end)
    end)

    %{account: account, room: room, peer: peer}
  end

  test "actual provider send retains authority while real session revocation waits, then rejects the withdrawn session",
       %{account: account, room: room} do
    parent = self()
    subject = Fixtures.subject(account)

    attrs = %{
      transaction_id: "native-race",
      generation: 1,
      membership_epoch: 1,
      content: %{
        "algorithm" => "m.megolm.v1.aes-sha2",
        "session_id" => Base.encode64(:binary.copy(<<1>>, 32), padding: false),
        "ciphertext" => Base.encode64(:binary.copy(<<2>>, 48), padding: false)
      }
    }

    sender =
      actor(parent, :sender, fn -> Messaging.send_private_event(room.id, attrs, subject) end)

    assert_receive {:sender_backend, sender_backend}, 5_000
    assert_receive {:native_send_retained, native}, 5_000

    revoker =
      actor(parent, :revoker, fn ->
        Accounts.revoke_own_session_command(account.session.id, subject)
      end)

    assert_receive {:revoker_backend, revoker_backend}, 5_000
    {query, blockers} = wait_for_lock(revoker_backend)
    assert sender_backend in blockers

    assert String.contains?(query, "pg_advisory_xact_lock") or
             String.contains?(query, "FOR NO KEY UPDATE")

    send(native, :release_native)
    assert {:ok, %{replayed: false}} = Task.await(sender, 10_000)
    assert :ok = Task.await(revoker, 10_000)

    assert {:error, :forbidden} =
             unboxed(fn ->
               Messaging.send_private_event(
                 room.id,
                 %{attrs | transaction_id: "after-revocation"},
                 subject
               )
             end)

    refute_receive {:native_send_retained, _}, 100
  end

  test "participant admission uses canonical User write exclusion before actor session resources",
       %{account: account, peer: peer} do
    parent = self()

    holder =
      actor(parent, :participant_holder, fn ->
        Repo.transaction(fn ->
          Repo.one!(
            from(u in CommsCore.Accounts.User, where: u.id == ^peer.id, lock: "FOR NO KEY UPDATE")
          )

          send(parent, :participant_user_retained)

          receive do
            :release_participant -> :ok
          after
            5_000 -> raise "participant lock barrier expired"
          end
        end)
      end)

    assert_receive {:participant_holder_backend, holder_backend}, 5_000
    assert_receive :participant_user_retained, 5_000

    creator =
      actor(parent, :creator, fn ->
        Conversations.create_private_room(
          %{
            id: Ecto.UUID.generate(),
            title: "Canonical participant admission",
            member_ids: [peer.id]
          },
          Fixtures.subject(account)
        )
      end)

    assert_receive {:creator_backend, creator_backend}, 5_000
    {query, blockers} = wait_for_lock(creator_backend)
    assert holder_backend in blockers
    assert String.contains?(query, "FOR NO KEY UPDATE")
    refute String.contains?(query, "FOR SHARE")
    send(holder.pid, :release_participant)
    assert {:ok, :ok} = Task.await(holder, 10_000)
    assert {:ok, _room} = Task.await(creator, 10_000)
  end

  test "one deadline includes actual participant lock wait and never admits a grant after expiry",
       %{account: account, room: room, peer: peer} do
    parent = self()

    holder =
      actor(parent, :deadline_holder, fn ->
        Repo.transaction(fn ->
          Repo.one!(
            from(u in CommsCore.Accounts.User, where: u.id == ^peer.id, lock: "FOR NO KEY UPDATE")
          )

          send(parent, :deadline_user_retained)

          receive do
            :release_deadline -> :ok
          after
            5_000 -> raise "deadline lock barrier expired"
          end
        end)
      end)

    assert_receive {:deadline_holder_backend, holder_backend}, 5_000
    assert_receive :deadline_user_retained, 5_000

    waiter =
      actor(parent, :deadline_waiter, fn ->
        deadline = System.monotonic_time(:millisecond) + 1000

        CommsCore.Conversations.PrivateBudget.transaction(deadline, fn ->
          case Conversations.lock_private_room_grant(
                 room.id,
                 Fixtures.subject(account),
                 1,
                 1,
                 deadline
               ) do
            {:ok, _grant} ->
              send(parent, :expired_grant_admitted)
              :admitted

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end)
      end)

    assert_receive {:deadline_waiter_backend, waiter_backend}, 5_000
    {_query, blockers} = wait_for_lock(waiter_backend)
    assert holder_backend in blockers
    assert {:error, :private_operation_timeout} = Task.await(waiter, 5_000)
    refute_receive :expired_grant_admitted, 50
    refute_receive {:native_send_retained, _}, 50
    send(holder.pid, :release_deadline)
    assert {:ok, :ok} = Task.await(holder, 5_000)
  end

  test "late native login receipt cannot resurrect an erasure-fenced generation with no private-room lineage",
       %{account: account} do
    parent = self()

    {user, subject} =
      unboxed(fn ->
        %{user: user} = Fixtures.user_fixture(account)

        subject =
          CommsCore.TrustGovernanceTestSupport.authenticated_subject(
            account,
            user,
            "Zero-room late login"
          )

        {user, subject}
      end)

    Application.put_env(:comms_core, :private_identity_login_barrier, {user.id, parent})

    issuer =
      actor(parent, :late_identity_issuer, fn -> Accounts.matrix_client_session(subject) end)

    assert_receive {:late_identity_issuer_backend, _}, 5_000
    assert_receive {:native_login_issued, native}, 5_000

    original =
      unboxed(fn -> Repo.get_by!(CommsCore.Accounts.MatrixIdentity, user_id: user.id) end)

    assert original.claim_id

    assert {:ok, :ok} =
             unboxed(fn ->
               Repo.transaction(fn ->
                 Accounts.prepare_matrix_identity_erasure(account.tenant.id, user.id)
               end)
             end)

    fenced = unboxed(fn -> Repo.get!(CommsCore.Accounts.MatrixIdentity, original.id) end)
    assert fenced.generation == original.generation + 1
    assert fenced.state == :cleanup_pending

    assert {:ok, %{"password" => password}} =
             CommsCore.Accounts.MatrixCredentials.open(fenced.auth_secret, fenced)

    assert is_binary(password)
    worker = CommsCore.RuntimePorts.job_worker!(:matrix_device_reconciler)

    assert {:ok, %{scanned: 0, revoked: 0}} =
             unboxed(fn -> Accounts.reconcile_matrix_devices(worker) end)

    send(native, :release_login)
    assert {:error, :matrix_claim_stale} = Task.await(issuer, 10_000)

    {identity, session} =
      unboxed(fn ->
        {Repo.get!(CommsCore.Accounts.MatrixIdentity, original.id),
         Repo.get_by!(CommsCore.Accounts.MatrixClientSession, session_id: subject.session_id)}
      end)

    assert identity.state == :cleanup_pending
    assert identity.generation == fenced.generation
    assert identity.claim_id == nil
    assert session.state == :cleanup_pending
    assert session.claim_id == nil

    assert {:ok, %{"access_token" => "race-auth-only"}} =
             CommsCore.Accounts.MatrixCredentials.open(session.credential_secret, session)

    assert {:error, :not_found} =
             unboxed(fn -> Accounts.matrix_identity_view(account.tenant.id, user.id) end)

    assert {:ok, %{revoked: 1}} = unboxed(fn -> Accounts.reconcile_matrix_devices(worker) end)

    assert unboxed(fn ->
             Repo.get!(CommsCore.Accounts.MatrixIdentity, identity.id).auth_secret
           end) == nil

    assert unboxed(fn -> Repo.get!(CommsCore.Accounts.MatrixClientSession, session.id).state end) ==
             :revoked

    assert unboxed(fn ->
             Accounts.matrix_identity_erasure_pending?(account.tenant.id, user.id)
           end)
  end

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
  defp wait_for_lock(_, 0), do: flunk("revocation did not reach an actual database lock wait")

  defp wait_for_lock(backend, attempts) do
    case unboxed(fn ->
           Repo.query!(
             "SELECT query,pg_blocking_pids(pid) FROM pg_stat_activity WHERE pid=$1 AND wait_event_type='Lock' AND cardinality(pg_blocking_pids(pid))>0",
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

  defp unboxed(operation), do: Sandbox.unboxed_run(Repo, operation)
end
