defmodule CommsCore.Accounts.GuestConversionAuthorityRaceTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias CommsCore.{Accounts, Conversations, Repo}
  alias CommsCore.Accounts.{Device, Session, User}
  alias CommsCore.Administration.Tenant
  alias CommsCore.Audit.AuditEvent
  alias CommsCore.Conversations.GuestLink
  alias CommsCore.Events.OutboxEvent
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :concurrency

  test "guest conversion cannot use authority that expires during its retained User wait" do
    {account, guest} =
      unboxed(fn ->
        account = Fixtures.account_fixture()
        register_cleanup(account.tenant.id)

        {:ok, {:ok, guest}} =
          Repo.transaction(fn ->
            Accounts.provision_guest_identity(%{
              tenant_id: account.tenant.id,
              display_name: "Bounded conversion guest",
              expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
              device: %{name: "Conversion race browser", platform: "test"}
            })
          end)

        {account, guest}
      end)

    subject = %{
      tenant_id: account.tenant.id,
      user_id: guest.user.id,
      device_id: guest.device.id,
      session_id: guest.session_id
    }

    expires_at =
      unboxed(fn ->
        expires_at = DateTime.add(DateTime.utc_now(), 3, :second)

        Repo.update_all(from(user in User, where: user.id == ^guest.user.id),
          set: [guest_expires_at: expires_at]
        )

        Repo.update_all(from(session in Session, where: session.id == ^guest.session_id),
          set: [expires_at: expires_at]
        )

        expires_at
      end)

    parent = self()

    holder =
      actor(fn ->
        Repo.transaction(fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows

          Repo.one!(
            from(user in User,
              where: user.id == ^guest.user.id,
              lock: "FOR NO KEY UPDATE"
            )
          )

          send(parent, {:retained_user, self(), backend})

          receive do
            :release_user -> :ok
          after
            8_000 -> raise "guest parent lock holder timed out"
          end
        end)
      end)

    assert_receive {:retained_user, holder_pid, holder_backend}, 5_000

    converter =
      actor(fn ->
        [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows
        send(parent, {:converter_backend, backend})

        Accounts.convert_guest_account(
          %{email: "expired-conversion@example.test", password: "converted-password-123"},
          subject,
          "expired-conversion@example.test"
        )
      end)

    assert_receive {:converter_backend, converter_backend}, 5_000
    {query, blockers} = wait_for_lock(converter_backend)
    assert String.contains?(query, ~s(FROM "users"))
    assert String.contains?(query, "FOR NO KEY UPDATE")
    assert holder_backend in blockers
    assert DateTime.compare(DateTime.utc_now(), expires_at) == :lt
    wait_for_expiry(expires_at)
    send(holder_pid, :release_user)
    assert {:ok, :ok} = Task.await(holder, 10_000)
    assert {:error, :session_expired} = Task.await(converter, 10_000)

    unboxed(fn ->
      assert %User{
               account_type: :guest,
               access_scope: :conversation_only,
               email: nil,
               password_hash: nil
             } = Repo.get!(User, guest.user.id)

      assert %Session{revoked_at: nil} = Repo.get!(Session, guest.session_id)
      assert %Device{revoked_at: nil} = Repo.get!(Device, guest.device.id)

      assert Repo.aggregate(
               from(session in Session, where: session.user_id == ^guest.user.id),
               :count
             ) == 1

      assert Repo.aggregate(
               from(device in Device, where: device.user_id == ^guest.user.id),
               :count
             ) == 1
    end)
  end

  test "a conversion-enabled link refuses step-up that expires during an actual INSERT wait" do
    account = unboxed(fn -> Fixtures.account_fixture() end)

    register_cleanup(account.tenant.id)

    subject = Fixtures.subject(account)

    expires_at =
      unboxed(fn ->
        ttl = Application.get_env(:comms_core, :step_up_ttl_seconds, 300)
        step_up_at = DateTime.add(DateTime.utc_now(), -ttl + 3, :second)

        Repo.update_all(from(session in Session, where: session.id == ^account.session.id),
          set: [step_up_at: step_up_at]
        )

        DateTime.add(step_up_at, ttl, :second)
      end)

    parent = self()

    holder =
      actor(fn ->
        Repo.transaction(fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows
          Repo.query!("LOCK TABLE conversation_guest_links IN SHARE MODE", [])
          send(parent, {:retained_link_relation, self(), backend})

          receive do
            :release_link_relation -> :ok
          after
            8_000 -> raise "conversion link relation holder timed out"
          end
        end)
      end)

    assert_receive {:retained_link_relation, holder_pid, holder_backend}, 5_000

    creator =
      actor(fn ->
        [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows
        send(parent, {:link_creator_backend, backend})

        Conversations.create_guest_link_view(
          account.conversation.id,
          %{
            expires_in_seconds: 3_600,
            max_uses: 1,
            conversion_email: "bound-person@example.test"
          },
          subject
        )
      end)

    assert_receive {:link_creator_backend, creator_backend}, 5_000
    {query, blockers} = wait_for_lock(creator_backend)
    assert String.contains?(query, ~s(INSERT INTO "conversation_guest_links"))
    assert holder_backend in blockers
    assert DateTime.compare(DateTime.utc_now(), expires_at) == :lt
    assert {:ok, %{step_up_recent?: true}} = unboxed(fn -> Accounts.access_grant(subject) end)
    wait_for_expiry(expires_at)
    send(holder_pid, :release_link_relation)
    assert {:ok, :ok} = Task.await(holder, 10_000)
    assert {:error, :step_up_required} = Task.await(creator, 10_000)

    unboxed(fn ->
      assert Repo.aggregate(
               from(link in GuestLink,
                 where: link.tenant_id == ^account.tenant.id
               ),
               :count
             ) == 0

      assert Repo.aggregate(
               from(event in AuditEvent,
                 where:
                   event.tenant_id == ^account.tenant.id and
                     event.action == "conversation.guest_link.created"
               ),
               :count
             ) == 0
    end)
  end

  defp register_cleanup(tenant_id) do
    on_exit(fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
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

  defp actor(operation) do
    task = Task.async(fn -> unboxed(operation) end)
    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    task
  end

  defp wait_for_lock(backend, attempts \\ 400)
  defp wait_for_lock(_, 0), do: flunk("guest converter did not reach a real User wait")

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
