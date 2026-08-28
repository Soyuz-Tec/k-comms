defmodule CommsCore.AdministrationMemberCapabilitiesTest do
  use CommsCore.DataCase, async: false

  @moduletag :integration

  alias CommsCore.Administration
  alias CommsCore.Administration.TenantSettings
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  describe "allow_immersive_mode" do
    test "is true while the tenant may place a call of either kind" do
      subject = tenant_with(allow_audio_calls: true, allow_video_calls: true)
      assert {:ok, %{allow_immersive_mode: true}} = Administration.member_capabilities(subject)

      subject = tenant_with(allow_audio_calls: true, allow_video_calls: false)
      assert {:ok, %{allow_immersive_mode: true}} = Administration.member_capabilities(subject)

      subject = tenant_with(allow_audio_calls: false, allow_video_calls: true)
      assert {:ok, %{allow_immersive_mode: true}} = Administration.member_capabilities(subject)
    end

    test "is false for a tenant that may not call at all" do
      # Immersive Mode is only entered after joining a call, so a tenant with
      # both call kinds disabled can never reach it.
      subject = tenant_with(allow_audio_calls: false, allow_video_calls: false)
      assert {:ok, capabilities} = Administration.member_capabilities(subject)
      assert capabilities.allow_immersive_mode == false
      assert capabilities.allow_audio_calls == false
      assert capabilities.allow_video_calls == false
    end
  end

  defp tenant_with(settings) do
    account = Fixtures.account_fixture()

    (Repo.get_by(TenantSettings, tenant_id: account.tenant.id) ||
       %TenantSettings{tenant_id: account.tenant.id})
    |> TenantSettings.changeset(Map.new(settings))
    |> Repo.insert_or_update!()

    Fixtures.subject(account)
  end
end
