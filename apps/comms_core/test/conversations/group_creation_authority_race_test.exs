defmodule CommsCore.Conversations.GroupCreationAuthorityRaceTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias CommsCore.{Accounts, AdmissionQuotas, Conversations, Repo, ServiceAccounts}
  alias CommsCore.Accounts.{Session, User}
  alias CommsCore.Administration.Tenant
  alias CommsCore.Conversations.{Conversation, Membership}
  alias CommsCore.Events.OutboxEvent
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :concurrency

  for operation <- [:device, :session] do
    @operation operation

    test "group creation rechecks #{operation} revocation committed during its actual quota wait" do
      {account, member} = fixture()
      subject = Fixtures.subject(account)
      parent = self()

      holder =
        actor(parent, :holder, fn ->
          Repo.transaction(fn ->
            :ok = AdmissionQuotas.lock_tenant(account.tenant.id)
            send(parent, {:quota_retained, self()})

            receive do
              :revoke ->
                assert_revoked(@operation, revoke(@operation, account, subject))
                :ok
            after
              10_000 -> raise "group quota lock holder timed out"
            end
          end)
        end)

      assert_receive {:holder_backend, holder_backend}, 5_000
      assert_receive {:quota_retained, holder_pid}, 5_000
      creator = actor(parent, :creator, fn -> create_group(account, member) end)
      assert_receive {:creator_backend, creator_backend}, 5_000

      {query, blockers} = wait_for_lock(creator_backend)
      assert String.contains?(query, "pg_advisory_xact_lock")
      assert holder_backend in blockers

      send(holder_pid, :revoke)
      assert {:ok, :ok} = Task.await(holder, 10_000)
      assert {:error, :forbidden} = Task.await(creator, 10_000)

      unboxed(fn ->
        assert Repo.get!(Session, account.session.id).revoked_at
        assert_group_effect_count(account.tenant.id, 0, 0)
      end)
    end
  end

  test "group creation retains actor User before Session and refuses a staggered real revocation" do
    {account, member} = fixture()
    subject = Fixtures.subject(account)
    parent = self()

    revoker =
      actor(parent, :revoker, fn -> revoke(:session, account, subject) end,
        barrier: fn query ->
          String.contains?(query, ~s(FROM "users")) and
            String.contains?(query, "FOR NO KEY UPDATE")
        end
      )

    assert_receive {:revoker_backend, revoker_backend}, 5_000
    assert_receive {:revoker_barrier, revoker_pid, release}, 5_000
    creator = actor(parent, :creator, fn -> create_group(account, member) end)
    assert_receive {:creator_backend, creator_backend}, 5_000

    {query, blockers} = wait_for_lock(creator_backend)
    assert sorted_users_share?(query)
    assert revoker_backend in blockers

    send(revoker_pid, {:release_barrier, release})
    assert :ok = Task.await(revoker, 10_000)
    assert {:error, :forbidden} = Task.await(creator, 10_000)

    unboxed(fn -> assert_group_effect_count(account.tenant.id, 0, 0) end)
  end

  test "a member suspended during the exact User row wait cannot become a new group participant" do
    {account, member} = fixture()
    parent = self()

    holder =
      actor(parent, :holder, fn ->
        Repo.transaction(fn ->
          Repo.one!(
            from(user in User,
              where: user.id == ^member.id and user.tenant_id == ^account.tenant.id,
              lock: "FOR UPDATE"
            )
          )

          send(parent, {:member_retained, self()})

          receive do
            :suspend ->
              {1, _} =
                Repo.update_all(
                  from(user in User,
                    where: user.id == ^member.id and user.tenant_id == ^account.tenant.id
                  ),
                  set: [status: :suspended]
                )

              :ok
          after
            10_000 -> raise "group member status lock holder timed out"
          end
        end)
      end)

    assert_receive {:holder_backend, holder_backend}, 5_000
    assert_receive {:member_retained, holder_pid}, 5_000
    creator = actor(parent, :creator, fn -> create_group(account, member) end)
    assert_receive {:creator_backend, creator_backend}, 5_000

    {query, blockers} = wait_for_lock(creator_backend)
    assert sorted_users_share?(query)
    assert holder_backend in blockers

    send(holder_pid, :suspend)
    assert {:ok, :ok} = Task.await(holder, 10_000)
    assert {:error, :invalid_members} = Task.await(creator, 10_000)

    unboxed(fn ->
      assert Repo.get!(User, member.id).status == :suspended
      assert_group_effect_count(account.tenant.id, 0, 0)
    end)
  end

  test "authorized group creation preserves active human and service membership semantics" do
    {account, member} = fixture()

    unboxed(fn ->
      subject = Fixtures.step_up(account)

      {:ok, service} =
        ServiceAccounts.create_view(
          %{
            name: "Current group identity service",
            scopes: ["conversations:read"],
            reason: "Verify unchanged service group eligibility"
          },
          subject
        )

      service_user_id = service.service_account.user_id

      assert {:ok, group} =
               Conversations.create_view(
                 %{
                   kind: "group",
                   title: "Current mixed identity group",
                   member_ids: [member.id, service_user_id]
                 },
                 subject
               )

      assert {:ok, memberships} = Conversations.list_member_views(group.id, subject)

      assert Enum.map(memberships, & &1.user_id) |> Enum.sort() ==
               Enum.sort([account.user.id, member.id, service_user_id])

      assert Enum.any?(memberships, fn membership ->
               membership.user_id == service_user_id and membership.user.account_type == :service
             end)

      assert_group_effect_count(account.tenant.id, 1, 3)
    end)
  end

  defp create_group(account, member) do
    Conversations.create_view(
      %{kind: "group", title: "Current authority group", member_ids: [member.id]},
      Fixtures.subject(account)
    )
  end

  defp fixture do
    {account, member} =
      unboxed(fn ->
        account = Fixtures.account_fixture()
        {account, Fixtures.user_fixture(account).user}
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

  defp assert_group_effect_count(tenant_id, groups, members) do
    ids =
      Repo.all(
        from(conversation in Conversation,
          where: conversation.tenant_id == ^tenant_id and conversation.kind == :group,
          select: conversation.id
        )
      )

    assert length(ids) == groups

    assert Repo.aggregate(
             from(member in Membership,
               where: member.tenant_id == ^tenant_id and member.conversation_id in ^ids
             ),
             :count
           ) == members

    assert Repo.aggregate(
             from(event in OutboxEvent,
               where:
                 event.tenant_id == ^tenant_id and event.aggregate_type == "conversation" and
                   event.aggregate_id in ^ids and event.event_type == "conversation.created.v1"
             ),
             :count
           ) == groups
  end

  defp revoke(:device, account, subject),
    do: Accounts.revoke_device_command(account.device.id, subject)

  defp revoke(:session, account, subject),
    do: Accounts.revoke_own_session_command(account.session.id, subject)

  defp assert_revoked(:device, result), do: assert(match?({:ok, _}, result))
  defp assert_revoked(:session, result), do: assert(result == :ok)

  defp sorted_users_share?(query),
    do:
      String.contains?(query, ~s(FROM "users")) and
        String.contains?(query, ~s(ORDER BY u0."id")) and String.contains?(query, "FOR SHARE")

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
              12_000 -> raise "group-creation query barrier timed out"
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

  defp unboxed(operation), do: Sandbox.unboxed_run(Repo, operation)
end
