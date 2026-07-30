defmodule CommsCore.Governance.OwnerLifecycleTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Accounts, Governance}
  alias CommsCore.Accounts.User
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :governance

  test "pending deletion requests still count toward governed owner lifecycle safety" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, second_owner} =
             Accounts.create_user(
               %{
                 display_name: "Pending deletion owner",
                 email: "pending-deletion-owner@example.test",
                 password: "correct-horse-pending-owner",
                 role: "admin"
               },
               subject
             )

    assert {:ok, second_owner} =
             Accounts.change_user(
               second_owner.id,
               %{version: second_owner.lock_version, role: "owner", reason: "share ownership"},
               subject
             )

    assert {:ok, %{request: pending_request}} =
             Governance.create_deletion_request(
               %{
                 target_type: "user",
                 subject_user_id: second_owner.id,
                 reason: "Pending request must not remove owner capacity"
               },
               subject
             )

    assert pending_request.status == :pending

    assert {:ok, %{user: demoted}} =
             Governance.change_user_lifecycle_view(
               account.user.id,
               %{
                 version: account.user.lock_version,
                 role: "admin",
                 reason: "pending request still leaves another owner"
               },
               subject
             )

    assert demoted.role == :admin
  end

  test "approved deletion requests are excluded from governed owner lifecycle safety" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, second_owner} =
             Accounts.create_user(
               %{
                 display_name: "Approved deletion owner",
                 email: "approved-deletion-owner@example.test",
                 password: "correct-horse-approved-owner",
                 role: "admin"
               },
               subject
             )

    assert {:ok, second_owner} =
             Accounts.change_user(
               second_owner.id,
               %{version: second_owner.lock_version, role: "owner", reason: "share ownership"},
               subject
             )

    assert {:ok, %{request: request}} =
             Governance.create_deletion_request(
               %{
                 target_type: "user",
                 subject_user_id: second_owner.id,
                 reason: "Approved owner deletion must reduce owner capacity"
               },
               subject
             )

    assert {:ok, approved} =
             Governance.transition_deletion_request(
               request.id,
               %{
                 version: request.lock_version,
                 status: "approved",
                 transition_reason: "approve owner deletion"
               },
               subject
             )

    assert approved.status == :approved

    assert {:error, :last_owner_required} =
             Governance.change_user_lifecycle_view(
               account.user.id,
               %{
                 version: account.user.lock_version,
                 role: "admin",
                 reason: "must preserve an effective owner"
               },
               subject
             )

    assert Repo.get!(User, account.user.id).role == :owner
  end
end
