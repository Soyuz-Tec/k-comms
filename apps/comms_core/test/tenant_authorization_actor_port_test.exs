defmodule CommsCore.Administration.AuthorizationActorPortTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts
  alias CommsCore.Administration.{AuthorizationActor, AuthorizationActorPort}
  alias CommsTestSupport.Fixtures

  defmodule MismatchedAdapter do
    @behaviour CommsCore.Administration.AuthorizationActorPort

    @impl true
    def resolve_authorization_actor(subject) do
      {:ok,
       %AuthorizationActor{
         tenant_id: Map.fetch!(subject, :tenant_id),
         user_id: Map.fetch!(subject, :user_id),
         request_id: "spoofed-request-id"
       }}
    end
  end

  setup do
    previous = Application.fetch_env(:comms_core, :tenant_authorization_actor_adapter)
    Application.put_env(:comms_core, :tenant_authorization_actor_adapter, Accounts)

    on_exit(fn ->
      case previous do
        {:ok, adapter} ->
          Application.put_env(:comms_core, :tenant_authorization_actor_adapter, adapter)

        :error ->
          Application.delete_env(:comms_core, :tenant_authorization_actor_adapter)
      end
    end)

    :ok
  end

  test "the configured IdentityAccess owner returns bounded audit attribution" do
    account = Fixtures.account_fixture()
    request_id = Ecto.UUID.generate()
    subject = account |> Fixtures.subject() |> Map.put(:request_id, request_id)

    assert {:ok,
            %AuthorizationActor{
              tenant_id: tenant_id,
              user_id: user_id,
              request_id: ^request_id
            }} = AuthorizationActorPort.resolve_authorization_actor(subject)

    assert tenant_id == account.tenant.id
    assert user_id == account.user.id
  end

  test "missing or mismatched providers fail closed" do
    subject = %{
      tenant_id: Ecto.UUID.generate(),
      user_id: Ecto.UUID.generate(),
      request_id: Ecto.UUID.generate()
    }

    Application.delete_env(:comms_core, :tenant_authorization_actor_adapter)

    assert {:error, :unknown_authorization_actor} =
             AuthorizationActorPort.resolve_authorization_actor(subject)

    Application.put_env(
      :comms_core,
      :tenant_authorization_actor_adapter,
      MismatchedAdapter
    )

    assert {:error, :unknown_authorization_actor} =
             AuthorizationActorPort.resolve_authorization_actor(subject)
  end
end
