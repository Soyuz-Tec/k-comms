defmodule CommsCore.Accounts.GovernanceAccessTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts
  alias CommsCore.Accounts.User
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  test "governance user validation accepts any existing exact-tenant identity" do
    account = Fixtures.account_fixture()
    suspended = Fixtures.user_fixture(account, %{status: :suspended}).user
    service = service_user_fixture(account)
    other_account = Fixtures.account_fixture()

    assert :ok = Accounts.validate_governance_user(account.tenant.id, account.user.id)
    assert :ok = Accounts.validate_governance_user(account.tenant.id, suspended.id)
    assert :ok = Accounts.validate_governance_user(account.tenant.id, service.id)

    assert {:error, :not_found} =
             Accounts.validate_governance_user(account.tenant.id, other_account.user.id)

    assert {:error, :not_found} =
             Accounts.validate_governance_user(other_account.tenant.id, account.user.id)

    assert {:error, :not_found} =
             Accounts.validate_governance_user(account.tenant.id, "not-a-user-id")
  end

  test "moderation assignee validation requires an active eligible tenant role" do
    account = Fixtures.account_fixture()
    admin = Fixtures.user_fixture(account, %{role: :admin}).user
    moderator = Fixtures.user_fixture(account, %{role: :moderator}).user
    member = Fixtures.user_fixture(account, %{role: :member}).user

    suspended_moderator =
      Fixtures.user_fixture(account, %{role: :moderator, status: :suspended}).user

    other_account = Fixtures.account_fixture()

    for eligible <- [account.user, admin, moderator] do
      assert :ok = Accounts.validate_moderation_assignee(account.tenant.id, eligible.id)
    end

    for invalid <- [member, suspended_moderator, other_account.user] do
      assert {:error, :invalid_assignee} =
               Accounts.validate_moderation_assignee(account.tenant.id, invalid.id)
    end

    assert {:error, :invalid_assignee} =
             Accounts.validate_moderation_assignee(other_account.tenant.id, moderator.id)

    assert {:error, :invalid_assignee} =
             Accounts.validate_moderation_assignee(account.tenant.id, "not-a-user-id")
  end

  test "retention actor is the earliest inserted active owner with deterministic ties" do
    account = Fixtures.account_fixture()
    second_owner = Fixtures.user_fixture(account, %{role: :owner}).user
    third_owner = Fixtures.user_fixture(account, %{role: :owner}).user
    base_time = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    set_inserted_at!(account.user.id, DateTime.add(base_time, -60, :second))
    set_inserted_at!(second_owner.id, DateTime.add(base_time, -30, :second))
    set_inserted_at!(third_owner.id, DateTime.add(base_time, -30, :second))

    assert {:ok, actor_id} = Accounts.retention_actor_id(account.tenant.id)
    assert actor_id == account.user.id

    account.user
    |> User.changeset(%{status: :suspended})
    |> Repo.update!()

    assert {:ok, actor_id} = Accounts.retention_actor_id(account.tenant.id)
    assert actor_id == Enum.min([second_owner.id, third_owner.id])

    User
    |> where([user], user.tenant_id == ^account.tenant.id and user.role == :owner)
    |> Repo.update_all(set: [status: :suspended, updated_at: base_time])

    assert {:error, :last_owner_required} = Accounts.retention_actor_id(account.tenant.id)
    assert {:error, :last_owner_required} = Accounts.retention_actor_id("not-a-tenant-id")
  end

  test "governance erasure validation is transaction-bound and enforces effective owners" do
    account = Fixtures.account_fixture()
    second_owner = Fixtures.user_fixture(account, %{role: :owner}).user
    member = Fixtures.user_fixture(account).user

    assert {:error, :transaction_required} =
             Accounts.ensure_governance_erasure_allowed(
               account.tenant.id,
               account.user.id,
               []
             )

    assert {:ok, {:error, :invalid_owner_exclusions}} =
             Repo.transaction(fn ->
               Accounts.ensure_governance_erasure_allowed(
                 account.tenant.id,
                 account.user.id,
                 ["not-a-user-id"]
               )
             end)

    assert {:ok, {:error, :not_found}} =
             Repo.transaction(fn ->
               Accounts.ensure_governance_erasure_allowed(
                 account.tenant.id,
                 Ecto.UUID.generate(),
                 []
               )
             end)

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Accounts.ensure_governance_erasure_allowed(
                 account.tenant.id,
                 account.user.id,
                 []
               )
             end)

    assert {:ok, {:error, :last_owner_required}} =
             Repo.transaction(fn ->
               Accounts.ensure_governance_erasure_allowed(
                 account.tenant.id,
                 account.user.id,
                 [second_owner.id]
               )
             end)

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Accounts.ensure_governance_erasure_allowed(
                 account.tenant.id,
                 member.id,
                 [account.user.id, second_owner.id]
               )
             end)
  end

  test "governance erasure validation locks tenant users in deterministic ID order" do
    account = Fixtures.account_fixture()
    _second_owner = Fixtures.user_fixture(account, %{role: :owner}).user
    parent = self()
    handler_id = {__MODULE__, :governance_erasure_user_lock_order, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler_id,
               [:comms_core, :repo, :query],
               fn _event, _measurements, metadata, test_pid ->
                 send(test_pid, {:governance_erasure_query, Map.get(metadata, :query, "")})
               end,
               parent
             )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Accounts.ensure_governance_erasure_allowed(
                 account.tenant.id,
                 account.user.id,
                 []
               )
             end)

    queries = collect_erasure_queries([])

    assert Enum.any?(queries, fn query ->
             String.contains?(query, ~s(FROM "users")) and
               String.contains?(query, ~s(ORDER BY)) and
               String.contains?(query, ~s("id")) and
               String.contains?(query, "FOR UPDATE")
           end)
  end

  defp service_user_fixture(account) do
    suffix = System.unique_integer([:positive, :monotonic])

    %User{}
    |> User.service_changeset(%{
      tenant_id: account.tenant.id,
      external_subject: "service:governance-#{suffix}",
      display_name: "Governance Service #{suffix}",
      email: "governance-#{suffix}@service.invalid",
      account_type: :service,
      role: :member,
      status: :active
    })
    |> Repo.insert!()
  end

  defp set_inserted_at!(user_id, timestamp) do
    User
    |> where([user], user.id == ^user_id)
    |> Repo.update_all(set: [inserted_at: timestamp, updated_at: timestamp])
  end

  defp collect_erasure_queries(acc) do
    receive do
      {:governance_erasure_query, query} -> collect_erasure_queries([query | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
