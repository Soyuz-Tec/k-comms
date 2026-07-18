defmodule CommsCore.AdministrationRetentionDefaultsTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Administration
  alias CommsCore.Administration.RetentionDefaults
  alias CommsTestSupport.Fixtures

  test "returns a persistence-neutral tenant-scoped retention projection" do
    account = Fixtures.account_fixture()
    other_account = Fixtures.account_fixture()

    assert {:ok,
            %RetentionDefaults{
              tenant_id: tenant_id,
              default_retention_days: nil
            }} = Administration.retention_defaults(account.tenant.id)

    assert tenant_id == account.tenant.id

    subject = Fixtures.step_up(account)

    assert {:ok, _settings} =
             Administration.update_tenant_settings(
               %{version: 1, default_retention_days: 30},
               subject
             )

    assert {:ok,
            %RetentionDefaults{
              tenant_id: tenant_id,
              default_retention_days: 30
            }} = Administration.retention_defaults(account.tenant.id)

    assert tenant_id == account.tenant.id

    assert {:ok,
            %RetentionDefaults{
              tenant_id: other_tenant_id,
              default_retention_days: nil
            }} = Administration.retention_defaults(other_account.tenant.id)

    assert other_tenant_id == other_account.tenant.id
  end

  test "rejects malformed tenant identifiers without querying persistence" do
    assert {:error, :invalid_tenant_id} = Administration.retention_defaults("not-a-uuid")
    assert {:error, :invalid_tenant_id} = Administration.retention_defaults(nil)
  end
end
