defmodule CommsCore.ServiceAccounts.RollbackScimCredentialProjectionTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Repo, ServiceAccounts}
  alias CommsCore.ServiceAccounts.ServiceAccount
  alias CommsTestSupport.Fixtures

  setup do
    owner = Fixtures.account_fixture()
    %{owner: owner, subject: Fixtures.step_up(owner)}
  end

  test "ordinary automation scopes remain compatible and either SCIM scope counts once", %{
    subject: subject
  } do
    create(subject, ["conversations:read", "messages:write"])
    assert ServiceAccounts.rollback_scim_credential_hazard_count() == 0

    create(subject, ["scim:read"])
    assert ServiceAccounts.rollback_scim_credential_hazard_count() == 1
    create(subject, ["scim:write"])
    assert ServiceAccounts.rollback_scim_credential_hazard_count() == 2
    create(subject, ["scim:read", "scim:write", "messages:read"])
    assert ServiceAccounts.rollback_scim_credential_hazard_count() == 3
  end

  test "revoked and expired credentials retain their persisted SCIM scope compatibility", %{
    subject: subject
  } do
    revoked = create(subject, ["scim:read"])

    assert {:ok, _} =
             ServiceAccounts.revoke_view(
               revoked.id,
               %{version: revoked.version, reason: "Retire rollback fixture"},
               subject
             )

    expired = create(subject, ["scim:write"])
    timestamp = DateTime.utc_now()

    Repo.get!(ServiceAccount, expired.id)
    |> Ecto.Changeset.change(
      status: :expired,
      inserted_at: DateTime.add(timestamp, -7200),
      expires_at: DateTime.add(timestamp, -3600)
    )
    |> Repo.update!()

    assert ServiceAccounts.rollback_scim_credential_hazard_count() == 2
  end

  test "the rollback snapshot includes SCIM credentials from every tenant", %{subject: subject} do
    create(subject, ["scim:read"])
    other = Fixtures.account_fixture()
    create(Fixtures.step_up(other), ["scim:write"])
    assert ServiceAccounts.rollback_scim_credential_hazard_count() == 2
  end

  defp create(subject, scopes) do
    assert {:ok, result} =
             ServiceAccounts.create_view(
               %{
                 name: "Rollback credential fixture",
                 scopes: scopes,
                 reason: "Exercise persisted scope compatibility"
               },
               subject
             )

    result.service_account
  end
end
