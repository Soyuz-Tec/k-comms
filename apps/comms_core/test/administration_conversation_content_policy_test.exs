defmodule CommsCore.AdministrationConversationContentPolicyTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Administration, Repo}
  alias CommsCore.Administration.{ConversationContentPolicy, TenantSettings}
  alias CommsTestSupport.Fixtures

  test "returns an Ecto-free, tenant-scoped policy with owner defaults" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok,
            %ConversationContentPolicy{
              tenant_id: tenant_id,
              message_edit_window_seconds: 86_400,
              max_attachment_bytes: 26_214_400
            } = policy} = Administration.conversation_content_policy(subject)

    assert tenant_id == account.tenant.id
    refute function_exported?(policy.__struct__, :__schema__, 1)
  end

  test "returns persisted content policy fields without unrelated capabilities" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    %TenantSettings{}
    |> TenantSettings.changeset(%{
      tenant_id: account.tenant.id,
      message_edit_window_seconds: 120,
      max_attachment_bytes: 2_048
    })
    |> Repo.insert!()

    assert {:ok,
            %ConversationContentPolicy{
              tenant_id: tenant_id,
              message_edit_window_seconds: 120,
              max_attachment_bytes: 2_048
            } = policy} = Administration.conversation_content_policy(subject)

    assert tenant_id == account.tenant.id

    assert Map.keys(Map.from_struct(policy)) |> Enum.sort() ==
             [:max_attachment_bytes, :message_edit_window_seconds, :tenant_id]
  end

  test "fails closed when identity access is invalid" do
    account = Fixtures.account_fixture()

    assert {:error, :forbidden} =
             Administration.conversation_content_policy(%{
               tenant_id: account.tenant.id,
               user_id: Ecto.UUID.generate()
             })

    assert {:error, :forbidden} = Administration.conversation_content_policy(nil)
  end
end
