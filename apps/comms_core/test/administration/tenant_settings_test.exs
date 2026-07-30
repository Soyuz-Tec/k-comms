defmodule CommsCore.Administration.TenantSettingsTest do
  use CommsCore.DataCase, async: false

  @moduletag :integration

  alias CommsCore.{Administration, Audit}
  alias CommsCore.Audit.Event
  alias CommsTestSupport.Fixtures

  test "tenant settings use optimistic versioning and privileged audit search" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, initial} = Administration.get_tenant_settings(subject)
    assert initial.settings.lock_version == 1

    assert {:ok, updated} =
             Administration.update_tenant_settings(
               %{
                 version: 1,
                 name: "Governed Workspace",
                 allow_public_channels: false,
                 default_retention_days: 365
               },
               subject
             )

    assert updated.tenant.name == "Governed Workspace"
    assert updated.settings.allow_public_channels == false
    assert updated.settings.default_retention_days == 365

    assert {:error, :stale_version} =
             Administration.update_tenant_settings(
               %{version: 1, max_attachment_bytes: 1000},
               subject
             )

    assert {:ok, audit} =
             Administration.list_audit_events(%{action: "tenant.settings_update"}, subject)

    assert [%Event{resource_id: tenant_id}] = audit.events
    assert tenant_id == account.tenant.id
  end

  test "tenant administration owns its named access policies" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert :ok = Administration.authorize_read_capabilities(subject)
    assert :ok = Administration.authorize_administer_tenant(subject)

    assert {:error, :step_up_required} =
             Administration.authorize_manage_invitations(subject)

    assert {:error, :step_up_required} =
             Administration.authorize_manage_settings(subject)

    assert {:error, :step_up_required} =
             Administration.authorize_audit_tenant(subject)

    denied_events =
      Audit.list(%{
        tenant_id: account.tenant.id,
        actor_user_id: account.user.id,
        action: "authorization.denied",
        limit: 10
      })

    assert Enum.any?(denied_events, fn event ->
             event.metadata["permission"] == "manage_tenant_settings" and
               event.metadata["reason"] == "step_up_required"
           end)

    stepped_up_subject = Fixtures.step_up(account, subject)

    assert :ok = Administration.authorize_read_capabilities(stepped_up_subject)
    assert :ok = Administration.authorize_administer_tenant(stepped_up_subject)
    assert :ok = Administration.authorize_manage_invitations(stepped_up_subject)
    assert :ok = Administration.authorize_manage_settings(stepped_up_subject)
    assert :ok = Administration.authorize_audit_tenant(stepped_up_subject)
    assert {:ok, _settings} = Administration.get_tenant_settings(stepped_up_subject)
    assert {:ok, []} = Administration.list_invitations(stepped_up_subject)
  end
end
