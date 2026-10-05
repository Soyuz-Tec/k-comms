defmodule CommsCore.Conversations.DirectConversationAuthorityRaceTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias CommsCore.{Accounts, Conversations, Repo}
  alias CommsCore.Accounts.{Device, Session}
  alias CommsCore.Administration.Tenant
  alias CommsCore.Conversations.{Conversation, Membership}
  alias CommsCore.Events.OutboxEvent
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :concurrency

  for operation <- [:device, :session] do
    @operation operation

    test "#{operation} revocation holding User does not deadlock a direct start or permit its effect" do
      {account, member} = fixture()
      subject = Fixtures.subject(account)
      parent = self()

      revoker =
        actor(parent, :revoker, fn -> revoke(@operation, account, subject) end,
          barrier: &user_revocation_lock?/1
        )

      assert_receive {:revoker_backend, revoker_backend}, 5_000
      assert_receive {:revoker_barrier, revoker_pid, release}, 5_000

      starter =
        actor(parent, :starter, fn ->
          Conversations.get_or_create_direct_view(member.id, subject)
        end)

      assert_receive {:starter_backend, starter_backend}, 5_000
      {query, blockers} = wait_for_lock(starter_backend)
      assert user_directory_lock?(query)
      assert revoker_backend in blockers

      # Before the fix the starter retained Session SHARE at this point.
      # Continuing the real revoker would then form User -> Session -> User.
      send(revoker_pid, {:release_barrier, release})
      assert_revoked(@operation, Task.await(revoker, 10_000))
      assert {:error, :forbidden} = Task.await(starter, 10_000)

      unboxed(fn ->
        assert Repo.get!(Session, account.session.id).revoked_at
        if @operation == :device, do: assert(Repo.get!(Device, account.device.id).revoked_at)
        assert_direct_effect_count(account.tenant.id, 0)
      end)
    end

    test "an authorized direct start retains sorted Users before overlapping #{operation} revocation" do
      {account, member} = fixture()
      subject = Fixtures.subject(account)
      parent = self()

      starter =
        actor(
          parent,
          :starter,
          fn -> Conversations.get_or_create_direct_view(member.id, subject) end,
          barrier: &user_directory_lock?/1
        )

      assert_receive {:starter_backend, starter_backend}, 5_000
      assert_receive {:starter_barrier, starter_pid, release}, 5_000

      revoker = actor(parent, :revoker, fn -> revoke(@operation, account, subject) end)
      assert_receive {:revoker_backend, revoker_backend}, 5_000
      {query, blockers} = wait_for_lock(revoker_backend)
      assert user_revocation_lock?(query)
      assert starter_backend in blockers

      send(starter_pid, {:release_barrier, release})
      assert {:ok, %{conversation: direct, created: true}} = Task.await(starter, 10_000)
      assert_revoked(@operation, Task.await(revoker, 10_000))

      unboxed(fn ->
        assert_direct_effect_count(account.tenant.id, 1)
        assert Repo.get!(Session, account.session.id).revoked_at

        assert Repo.all(
                 from(member in Membership,
                   where:
                     member.tenant_id == ^account.tenant.id and
                       member.conversation_id == ^direct.id and is_nil(member.left_at),
                   order_by: [asc: member.user_id],
                   select: member.user_id
                 )
               ) == Enum.sort([account.user.id, member.id])
      end)
    end
  end

  test "direct resume denies authority that expires during an actual Conversation lock wait" do
    {account, member} = fixture()
    subject = Fixtures.subject(account)

    {direct, expires_at} =
      unboxed(fn ->
        {:ok, %{conversation: direct}} =
          Conversations.get_or_create_direct_view(member.id, subject)

        expiry = DateTime.add(DateTime.utc_now(), 3, :second)

        {1, _} =
          Repo.update_all(from(session in Session, where: session.id == ^account.session.id),
            set: [expires_at: expiry]
          )

        {direct, expiry}
      end)

    parent = self()

    holder =
      actor(parent, :holder, fn ->
        Repo.transaction(fn ->
          Repo.one!(
            from(conversation in Conversation,
              where:
                conversation.id == ^direct.id and conversation.tenant_id == ^account.tenant.id,
              lock: "FOR UPDATE"
            )
          )

          send(parent, {:conversation_retained, self()})

          receive do
            :release_conversation -> :ok
          after
            10_000 -> raise "direct Conversation lock holder timed out"
          end
        end)
      end)

    assert_receive {:holder_backend, holder_backend}, 5_000
    assert_receive {:conversation_retained, holder_pid}, 5_000

    starter =
      actor(parent, :starter, fn ->
        Conversations.get_or_create_direct_view(member.id, subject)
      end)

    assert_receive {:starter_backend, starter_backend}, 5_000
    {query, blockers} = wait_for_lock(starter_backend)
    assert String.contains?(query, ~s(FROM "conversations"))
    assert holder_backend in blockers

    wait_for_expiry(expires_at)
    send(holder_pid, :release_conversation)
    assert {:ok, :ok} = Task.await(holder, 10_000)
    assert {:error, :forbidden} = Task.await(starter, 10_000)

    unboxed(fn ->
      assert_direct_effect_count(account.tenant.id, 1)
      refute Repo.get!(Session, account.session.id).revoked_at
    end)
  end

  defp fixture do
    {account, member} =
      unboxed(fn ->
        account = Fixtures.account_fixture()
        member = Fixtures.user_fixture(account).user
        {account, member}
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
              where:
                fragment("?->>'tenant_id' = ?", job.args, ^account.tenant.id) or
                  fragment("?->>'event_id' = ANY(?::text[])", job.args, ^event_ids)
            )
          )

          Repo.delete_all(from(tenant in Tenant, where: tenant.id == ^account.tenant.id))
        end)
      end)
    end)

    {account, member}
  end

  defp assert_direct_effect_count(tenant_id, expected) do
    ids =
      Repo.all(
        from(conversation in Conversation,
          where: conversation.tenant_id == ^tenant_id and conversation.kind == :direct,
          select: conversation.id
        )
      )

    assert length(ids) == expected

    assert Repo.aggregate(
             from(member in Membership,
               where: member.tenant_id == ^tenant_id and member.conversation_id in ^ids
             ),
             :count
           ) == expected * 2

    assert Repo.aggregate(
             from(event in OutboxEvent,
               where:
                 event.tenant_id == ^tenant_id and event.aggregate_type == "conversation" and
                   event.aggregate_id in ^ids and event.event_type == "conversation.created.v1"
             ),
             :count
           ) == expected
  end

  defp revoke(:device, account, subject),
    do: Accounts.revoke_device_command(account.device.id, subject)

  defp revoke(:session, account, subject),
    do: Accounts.revoke_own_session_command(account.session.id, subject)

  defp assert_revoked(:device, result), do: assert(match?({:ok, _}, result))
  defp assert_revoked(:session, result), do: assert(result == :ok)

  defp user_directory_lock?(query),
    do:
      String.contains?(query, ~s(FROM "users")) and
        String.contains?(query, ~s(ORDER BY u0."id")) and String.contains?(query, "FOR SHARE")

  defp user_revocation_lock?(query),
    do:
      String.contains?(query, ~s(FROM "users")) and
        String.contains?(query, "FOR NO KEY UPDATE")

  defp actor(parent, label, operation, opts \\ []) do
    task =
      Task.async(fn ->
        unboxed(fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows
          send(parent, {String.to_atom("#{label}_backend"), backend})
          if matcher = Keyword.get(opts, :barrier), do: attach_barrier(parent, label, matcher)
          operation.()
        end)
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    task
  end

  defp attach_barrier(parent, label, matcher) do
    handler = {__MODULE__, make_ref()}
    release = make_ref()
    actor = self()

    :ok =
      :telemetry.attach(
        handler,
        [:comms_core, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == actor and matcher.(metadata.query) do
            :telemetry.detach(handler)
            send(parent, {String.to_atom("#{label}_barrier"), self(), release})

            receive do
              {:release_barrier, ^release} -> :ok
            after
              12_000 -> raise "direct-conversation query barrier timed out"
            end
          end
        end,
        nil
      )
  end

  defp wait_for_lock(backend, attempts \\ 300)
  defp wait_for_lock(_backend, 0), do: flunk("actor did not reach an actual database lock wait")

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

  defp wait_for_expiry(expires_at) do
    if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
      Process.sleep(10)
      wait_for_expiry(expires_at)
    end
  end

  defp unboxed(operation), do: Sandbox.unboxed_run(Repo, operation)
end
