defmodule CommsCore.Administration.IdentityAccessPortTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts
  alias CommsCore.Administration.{IdentityAccessPort, IdentityGrant}
  alias CommsTestSupport.Fixtures

  defmodule MismatchedAdapter do
    @behaviour CommsCore.Administration.IdentityAccessPort

    @impl true
    def resolve_access(_subject) do
      {:ok,
       %IdentityGrant{
         tenant_id: Ecto.UUID.generate(),
         user_id: Ecto.UUID.generate(),
         role: :owner,
         step_up_recent?: true
       }}
    end
  end

  setup do
    previous = Application.fetch_env(:comms_core, :tenant_identity_access_adapter)
    Application.put_env(:comms_core, :tenant_identity_access_adapter, Accounts)

    on_exit(fn ->
      case previous do
        {:ok, adapter} ->
          Application.put_env(:comms_core, :tenant_identity_access_adapter, adapter)

        :error ->
          Application.delete_env(:comms_core, :tenant_identity_access_adapter)
      end
    end)

    :ok
  end

  test "the configured IdentityAccess owner returns bounded tenant facts" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok,
            %IdentityGrant{
              tenant_id: tenant_id,
              user_id: user_id,
              role: :owner,
              step_up_recent?: false
            }} = IdentityAccessPort.resolve_access(subject)

    assert tenant_id == account.tenant.id
    assert user_id == account.user.id
  end

  test "missing, incomplete, or mismatched providers fail closed" do
    subject = %{
      tenant_id: Ecto.UUID.generate(),
      user_id: Ecto.UUID.generate()
    }

    Application.delete_env(:comms_core, :tenant_identity_access_adapter)
    assert {:error, :forbidden} = IdentityAccessPort.resolve_access(subject)

    Application.put_env(
      :comms_core,
      :tenant_identity_access_adapter,
      MismatchedAdapter
    )

    assert {:error, :forbidden} = IdentityAccessPort.resolve_access(subject)
  end
end
