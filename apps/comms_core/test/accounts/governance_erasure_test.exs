defmodule CommsCore.Accounts.GovernanceErasureTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts
  alias CommsCore.Accounts.{Device, Session, User}
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :governance

  test "governance erasure requires a caller-owned transaction" do
    account = Fixtures.account_fixture()
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:error, :invalid_erasure_command} =
             Accounts.erase_user_for_governance(%{
               tenant_id: account.tenant.id,
               user_id: "not-a-uuid",
               pending_deletion_user_ids: [],
               timestamp: timestamp
             })

    assert {:error, :transaction_required} =
             Accounts.erase_user_for_governance(%{
               tenant_id: account.tenant.id,
               user_id: account.user.id,
               pending_deletion_user_ids: [],
               timestamp: timestamp
             })
  end

  test "governance erasure anonymizes the user and revokes IdentityAccess state" do
    account = Fixtures.account_fixture()
    _remaining_owner = Fixtures.user_fixture(account, %{role: :owner})
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    original_version = account.user.lock_version

    assert {:ok, {:ok, %{user_id: user_id, revoked_session_ids: revoked_session_ids}}} =
             Repo.transaction(fn ->
               Accounts.erase_user_for_governance(%{
                 tenant_id: account.tenant.id,
                 user_id: account.user.id,
                 pending_deletion_user_ids: [],
                 timestamp: timestamp
               })
             end)

    assert user_id == account.user.id
    assert revoked_session_ids == [account.session.id]

    erased_user = Repo.get!(User, account.user.id)
    assert erased_user.external_subject == "deleted-#{account.user.id}"
    assert erased_user.display_name == "Deleted user"
    assert erased_user.email == "deleted-#{account.user.id}@invalid.example"
    assert erased_user.status == :deleted
    assert erased_user.lock_version == original_version + 1

    assert Repo.get!(Session, account.session.id).revoked_at == timestamp
    assert Repo.get!(Device, account.device.id).revoked_at == timestamp
  end

  test "governance erasure excludes pending deletions from last-owner safety" do
    account = Fixtures.account_fixture()
    pending_owner = Fixtures.user_fixture(account, %{role: :owner}).user
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, {:error, :last_owner_required}} =
             Repo.transaction(fn ->
               Accounts.erase_user_for_governance(%{
                 tenant_id: account.tenant.id,
                 user_id: account.user.id,
                 pending_deletion_user_ids: [pending_owner.id],
                 timestamp: timestamp
               })
             end)

    assert Repo.get!(User, account.user.id).status == :active
    refute Repo.get!(Session, account.session.id).revoked_at
    refute Repo.get!(Device, account.device.id).revoked_at
  end
end
