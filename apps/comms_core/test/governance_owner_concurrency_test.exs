defmodule CommsCore.GovernanceOwnerConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias CommsCore.Accounts
  alias CommsCore.Accounts.{User, UserView}
  alias CommsCore.Administration.Tenant
  alias CommsCore.Governance
  alias CommsCore.Governance.{DeletionRequest, DeletionRequestView}
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @repo_query_event [:comms_core, :repo, :query]
  @governance_lock_sql "pg_advisory_xact_lock(hashtextextended($1, 0))"

  test "deletion approval commits before and blocks owner demotion" do
    fixture = race_fixture()

    {approval, demotion} =
      serialized_race(
        fixture.tenant_id,
        fn -> approve_deletion(fixture) end,
        fn -> demote_original_owner(fixture) end
      )

    assert {:ok, %DeletionRequestView{status: :approved}} = approval
    assert {:error, :last_owner_required} = demotion
    assert_persisted_owner_invariant(fixture)
  end

  test "owner demotion commits before and blocks deletion approval" do
    fixture = race_fixture()

    {demotion, approval} =
      serialized_race(
        fixture.tenant_id,
        fn -> demote_original_owner(fixture) end,
        fn -> approve_deletion(fixture) end
      )

    assert {:ok, %{user: %UserView{role: :admin}}} = demotion
    assert {:error, :last_owner_required} = approval
    assert_persisted_owner_invariant(fixture)
  end

  test "deletion transition reauthorizes after acquiring the governance lock" do
    fixture = authorization_race_fixture()
    parent = self()
    release_ref = make_ref()
    handler_id = {__MODULE__, make_ref()}

    on_exit(fn -> :telemetry.detach(handler_id) end)

    transition =
      Task.async(fn ->
        unboxed(fn ->
          attach_lock_barrier(handler_id, parent, release_ref, fixture.tenant_id)

          try do
            approve_deletion(fixture)
          after
            :telemetry.detach(handler_id)
          end
        end)
      end)

    transition_pid = transition.pid

    assert_receive {:governance_lock_acquired, ^transition_pid, tenant_id}, 5_000
    assert tenant_id == fixture.tenant_id

    assert {:ok, suspended_actor} =
             unboxed(fn ->
               Accounts.change_user(
                 fixture.subject.user_id,
                 %{
                   version: fixture.actor_version,
                   status: "suspended",
                   reason: "revoke governance authority during lock wait"
                 },
                 fixture.owner_subject
               )
             end)

    assert suspended_actor.status == :suspended
    send(transition_pid, {:release_governance_lock, release_ref})

    assert {:error, :forbidden} = Task.await(transition, 15_000)

    persisted_request =
      unboxed(fn -> Repo.get!(DeletionRequest, fixture.request.id) end)

    assert persisted_request.status == :pending
  end

  defp race_fixture do
    account = unboxed(&Fixtures.account_fixture/0)
    tenant_id = account.tenant.id

    register_cleanup(tenant_id)

    password = "correct-horse-concurrent-owner"

    {request, subject} =
      unboxed(fn ->
        {:ok, second_owner} =
          Accounts.create_user(
            %{
              display_name: "Concurrent deletion owner",
              email: "concurrent-owner-#{System.unique_integer([:positive])}@example.test",
              password: password,
              role: "admin"
            },
            Fixtures.step_up(account)
          )

        {:ok, second_owner} =
          Accounts.change_user(
            second_owner.id,
            %{
              version: second_owner.lock_version,
              role: "owner",
              reason: "establish concurrent owner"
            },
            Fixtures.step_up(account)
          )

        {:ok, authentication} =
          Accounts.authenticate_view(
            account.tenant.slug,
            second_owner.email,
            password,
            %{name: "Concurrent owner browser", platform: "test"}
          )

        subject = %{
          tenant_id: tenant_id,
          user_id: second_owner.id,
          device_id: authentication.device.id,
          session_id: authentication.session_id,
          role: :owner,
          request_id: "owner-concurrency-test"
        }

        {:ok, _session} = Accounts.step_up(%{current_password: password}, subject)

        {:ok, %{request: request}} =
          Governance.create_deletion_request_view(
            %{
              target_type: "user",
              subject_user_id: second_owner.id,
              reason: "exercise owner safety under concurrent transitions"
            },
            subject
          )

        {request, subject}
      end)

    %{
      tenant_id: tenant_id,
      original_owner_id: account.user.id,
      original_owner_version: account.user.lock_version,
      request: request,
      subject: subject
    }
  end

  defp authorization_race_fixture do
    account = unboxed(&Fixtures.account_fixture/0)
    tenant_id = account.tenant.id
    register_cleanup(tenant_id)
    password = "correct-horse-concurrent-governor"

    unboxed(fn ->
      owner_subject = Fixtures.step_up(account)

      {:ok, actor} =
        Accounts.create_user(
          %{
            display_name: "Concurrent compliance actor",
            email: "concurrent-governor-#{System.unique_integer([:positive])}@example.test",
            password: password,
            role: "compliance_admin"
          },
          owner_subject
        )

      {:ok, target} =
        Accounts.create_user(
          %{
            display_name: "Concurrent deletion target",
            email: "concurrent-target-#{System.unique_integer([:positive])}@example.test",
            password: "correct-horse-concurrent-target",
            role: "member"
          },
          owner_subject
        )

      {:ok, authentication} =
        Accounts.authenticate_view(
          account.tenant.slug,
          actor.email,
          password,
          %{name: "Concurrent governance browser", platform: "test"}
        )

      subject = %{
        tenant_id: tenant_id,
        user_id: actor.id,
        device_id: authentication.device.id,
        session_id: authentication.session_id,
        role: :compliance_admin,
        request_id: "governance-reauthorization-test"
      }

      {:ok, _session} = Accounts.step_up(%{current_password: password}, subject)

      {:ok, %{request: request}} =
        Governance.create_deletion_request_view(
          %{
            target_type: "user",
            subject_user_id: target.id,
            reason: "prove authorization is fresh after serialization"
          },
          subject
        )

      %{
        tenant_id: tenant_id,
        actor_version: actor.lock_version,
        owner_subject: owner_subject,
        request: request,
        subject: subject
      }
    end)
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

  defp serialized_race(tenant_id, first_operation, second_operation) do
    parent = self()
    start_ref = make_ref()
    release_ref = make_ref()
    handler_id = {__MODULE__, make_ref()}

    on_exit(fn -> :telemetry.detach(handler_id) end)

    first =
      Task.async(fn ->
        unboxed(fn ->
          backend_pid = database_backend_pid()
          send(parent, {:connection_ready, :first, self(), backend_pid})
          await_start(start_ref)

          attach_lock_barrier(handler_id, parent, release_ref, tenant_id)

          try do
            first_operation.()
          after
            :telemetry.detach(handler_id)
          end
        end)
      end)

    second =
      Task.async(fn ->
        unboxed(fn ->
          backend_pid = database_backend_pid()
          send(parent, {:connection_ready, :second, self(), backend_pid})
          await_start(start_ref)
          second_operation.()
        end)
      end)

    first_pid = first.pid
    second_pid = second.pid

    assert_receive {:connection_ready, :first, ^first_pid, first_backend_pid}, 5_000
    assert_receive {:connection_ready, :second, ^second_pid, second_backend_pid}, 5_000
    refute first_backend_pid == second_backend_pid

    send(first_pid, {:start, start_ref})
    assert_receive {:governance_lock_acquired, ^first_pid, ^tenant_id}, 5_000

    send(second_pid, {:start, start_ref})
    refute Task.yield(second, 250)

    send(first_pid, {:release_governance_lock, release_ref})

    first_result = Task.await(first, 15_000)
    second_result = Task.await(second, 15_000)

    {first_result, second_result}
  end

  defp attach_lock_barrier(handler_id, parent, release_ref, tenant_id) do
    target_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @repo_query_event,
        fn _event, _measurements, metadata, config ->
          if self() == config.target_pid and governance_lock_query?(metadata) do
            send(config.parent, {:governance_lock_acquired, self(), config.tenant_id})

            receive do
              {:release_governance_lock, ^release_ref} -> :ok
            after
              5_000 -> raise "governance lock barrier timed out"
            end
          end
        end,
        %{parent: parent, target_pid: target_pid, tenant_id: tenant_id}
      )
  end

  defp approve_deletion(fixture) do
    Governance.transition_deletion_request_view(
      fixture.request.id,
      %{
        version: fixture.request.version,
        status: "approved",
        transition_reason: "approve concurrent owner deletion"
      },
      fixture.subject
    )
  end

  defp demote_original_owner(fixture) do
    Governance.change_user_lifecycle_view(
      fixture.original_owner_id,
      %{
        version: fixture.original_owner_version,
        role: "admin",
        reason: "race owner demotion against deletion approval"
      },
      fixture.subject
    )
  end

  defp assert_persisted_owner_invariant(fixture) do
    {owner, request} =
      unboxed(fn ->
        {
          Repo.get!(User, fixture.original_owner_id),
          Repo.get!(DeletionRequest, fixture.request.id)
        }
      end)

    refute owner.role != :owner and request.status == :approved
  end

  defp governance_lock_query?(%{query: query}) when is_binary(query),
    do: String.contains?(query, @governance_lock_sql)

  defp governance_lock_query?(_metadata), do: false

  defp database_backend_pid do
    {:ok, %{rows: [[backend_pid]]}} =
      Ecto.Adapters.SQL.query(Repo, "SELECT pg_backend_pid()", [])

    backend_pid
  end

  defp await_start(start_ref) do
    receive do
      {:start, ^start_ref} -> :ok
    after
      5_000 -> raise "concurrency test start barrier timed out"
    end
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
