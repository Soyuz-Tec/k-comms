defmodule CommsCore.Governance.EligibleOwnerErasureTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Governance, Repo}
  alias CommsCore.Accounts.User
  alias CommsCore.Governance.DeletionRequest
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :governance

  test "limited human and service owners cannot justify erasure of the last workspace owner" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    legacy =
      Fixtures.user_fixture(account, %{role: :owner}).user
      |> Ecto.Changeset.change(access_scope: :conversation_only)
      |> Repo.update!()

    service = Fixtures.user_fixture(account, %{role: :owner, account_type: :service}).user
    assert legacy.access_scope == :conversation_only
    assert service.account_type == :service

    assert {:ok, %{request: request}} =
             Governance.create_deletion_request(
               %{
                 target_type: "user",
                 subject_user_id: account.user.id,
                 reason: "Attempt removal of the final eligible workspace owner"
               },
               subject
             )

    assert {:error, :last_owner_required} =
             Governance.transition_deletion_request(
               request.id,
               %{
                 version: request.lock_version,
                 status: "approved",
                 transition_reason: "Unusable predecessor owners must not count"
               },
               subject
             )

    assert Repo.get!(DeletionRequest, request.id).status == :pending
    assert Repo.get!(User, account.user.id).status == :active
    assert Repo.get!(User, account.user.id).lock_version == account.user.lock_version
  end

  test "governed erasure can clean up a limited legacy owner with no eligible workspace owner" do
    account = Fixtures.account_fixture()

    legacy =
      Fixtures.user_fixture(account, %{role: :owner}).user
      |> Ecto.Changeset.change(access_scope: :conversation_only)
      |> Repo.update!()

    # Current governed changes refuse this predecessor state. A compliance
    # administrator must still be able to erase its unusable legacy identity.
    actor = account.user |> Ecto.Changeset.change(role: :compliance_admin) |> Repo.update!()
    subject = Fixtures.step_up(%{account | user: actor})
    assert actor.role == :compliance_admin and actor.access_scope == :workspace
    assert legacy.role == :owner and legacy.access_scope == :conversation_only

    assert {:ok, %{request: request}} =
             Governance.create_deletion_request(
               %{
                 target_type: "user",
                 subject_user_id: legacy.id,
                 reason: "Remove an unusable scoped predecessor identity"
               },
               subject
             )

    assert {:ok, approved} =
             Governance.transition_deletion_request(
               request.id,
               %{
                 version: request.lock_version,
                 status: "approved",
                 transition_reason: "Scoped predecessor is outside workspace ownership"
               },
               subject
             )

    worker = CommsCore.RuntimePorts.job_worker!(:deletion)
    assert {:ok, execution} = Governance.claim_deletion_request(approved.id, worker)

    assert {:ok, completed} =
             Governance.complete_deletion_request(
               execution.request_id,
               execution.expected_version,
               %{deleted_object_count: 0},
               worker
             )

    assert completed.request.status == :completed
    assert Repo.get!(User, legacy.id).status == :deleted
    assert Repo.get!(User, actor.id).role == :compliance_admin
    assert Repo.get!(User, actor.id).status == :active
  end
end
