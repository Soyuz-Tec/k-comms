defmodule CommsCore.Administration.InvitationIdentityPortTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Administration.{
    AdmissionPolicy,
    InvitationIdentityAuthorization,
    InvitationIdentityPort,
    InvitedIdentityReceipt,
    InvitedUserCommand
  }

  alias CommsCore.Repo

  defmodule RecordingAdapter do
    @behaviour CommsCore.Administration.InvitationIdentityPort

    alias CommsCore.Administration.{
      InvitationIdentityAuthorization,
      InvitedIdentityReceipt,
      InvitedUserCommand
    }

    @impl true
    def authorize_invitation(%InvitationIdentityAuthorization{} = authorization) do
      send(self(), {:authorize_invitation, authorization})
      :ok
    end

    @impl true
    def validate_invitation_password(password) do
      send(self(), {:validate_invitation_password, password})
      :ok
    end

    @impl true
    def ensure_invitation_identity_available(tenant_id, email) do
      send(self(), {:ensure_invitation_identity_available, tenant_id, email})
      :ok
    end

    @impl true
    def enroll_invited_user(%InvitedUserCommand{} = command) do
      send(self(), {:enroll_invited_user, command})

      receipt = %InvitedIdentityReceipt{
        id: Ecto.UUID.generate(),
        tenant_id: command.tenant_id,
        display_name: command.display_name,
        email: String.upcase(command.email),
        account_type: :human,
        role: command.role,
        status: :active,
        version: 1
      }

      case Process.get(:invited_identity_receipt_mutation) do
        mutation when is_function(mutation, 1) -> {:ok, mutation.(receipt)}
        _ -> {:ok, receipt}
      end
    end
  end

  defmodule ErrorAdapter do
    @behaviour CommsCore.Administration.InvitationIdentityPort

    @impl true
    def authorize_invitation(_authorization), do: {:error, :forced_authorization_failure}

    @impl true
    def validate_invitation_password(_password), do: {:error, :weak_password}

    @impl true
    def ensure_invitation_identity_available(_tenant_id, _email),
      do: {:error, :invitation_identity_conflict}

    @impl true
    def enroll_invited_user(_command), do: {:error, :forced_enrollment_failure}
  end

  defmodule UnexpectedAdapter do
    @behaviour CommsCore.Administration.InvitationIdentityPort

    @impl true
    def authorize_invitation(_authorization), do: :unexpected

    @impl true
    def validate_invitation_password(_password), do: %{unexpected: true}

    @impl true
    def ensure_invitation_identity_available(_tenant_id, _email), do: {:ok, :unexpected}

    @impl true
    def enroll_invited_user(_command), do: {:ok, %{unexpected: true}}
  end

  defmodule MissingOperationAdapter do
    def authorize_invitation(_authorization), do: :ok
  end

  setup do
    previous_adapter =
      Application.fetch_env(:comms_core, :tenant_invitation_identity_adapter)

    Application.put_env(
      :comms_core,
      :tenant_invitation_identity_adapter,
      RecordingAdapter
    )

    on_exit(fn ->
      Process.delete(:invited_identity_receipt_mutation)

      case previous_adapter do
        {:ok, adapter} ->
          Application.put_env(
            :comms_core,
            :tenant_invitation_identity_adapter,
            adapter
          )

        :error ->
          Application.delete_env(:comms_core, :tenant_invitation_identity_adapter)
      end
    end)

    :ok
  end

  test "every configured adapter operation requires the caller transaction" do
    authorization = authorization()
    command = invited_user_command(authorization)

    assert {:error, :transaction_required} =
             InvitationIdentityPort.authorize_invitation(authorization)

    assert {:error, :transaction_required} =
             InvitationIdentityPort.validate_invitation_password(command.password)

    assert {:error, :transaction_required} =
             InvitationIdentityPort.ensure_invitation_identity_available(
               command.tenant_id,
               command.email
             )

    assert {:error, :transaction_required} =
             InvitationIdentityPort.enroll_invited_user(command)

    refute_received {:authorize_invitation, _authorization}
    refute_received {:validate_invitation_password, _password}
    refute_received {:ensure_invitation_identity_available, _tenant_id, _email}
    refute_received {:enroll_invited_user, _command}
  end

  test "the port dispatches only the declared operations and accepts an exact receipt" do
    authorization = authorization()
    command = invited_user_command(authorization)

    assert {:ok, :complete} =
             Repo.transaction(fn ->
               assert :ok = InvitationIdentityPort.authorize_invitation(authorization)

               assert :ok =
                        InvitationIdentityPort.validate_invitation_password(command.password)

               assert :ok =
                        InvitationIdentityPort.ensure_invitation_identity_available(
                          command.tenant_id,
                          command.email
                        )

               assert {:ok, %InvitedIdentityReceipt{} = receipt} =
                        InvitationIdentityPort.enroll_invited_user(command)

               assert receipt.tenant_id == command.tenant_id
               assert String.downcase(receipt.email) == command.email
               assert receipt.role == command.role
               :complete
             end)

    assert_receive {:authorize_invitation, ^authorization}
    assert_receive {:validate_invitation_password, password}
    assert password == command.password

    assert_receive {:ensure_invitation_identity_available, tenant_id, email}
    assert tenant_id == command.tenant_id
    assert email == command.email

    assert_receive {:enroll_invited_user, ^command}
  end

  test "declared owner errors cross the port unchanged" do
    Application.put_env(
      :comms_core,
      :tenant_invitation_identity_adapter,
      ErrorAdapter
    )

    authorization = authorization()
    command = invited_user_command(authorization)

    assert {:ok, :verified} =
             Repo.transaction(fn ->
               assert {:error, :forced_authorization_failure} =
                        InvitationIdentityPort.authorize_invitation(authorization)

               assert {:error, :weak_password} =
                        InvitationIdentityPort.validate_invitation_password(command.password)

               assert {:error, :invitation_identity_conflict} =
                        InvitationIdentityPort.ensure_invitation_identity_available(
                          command.tenant_id,
                          command.email
                        )

               assert {:error, :forced_enrollment_failure} =
                        InvitationIdentityPort.enroll_invited_user(command)

               :verified
             end)
  end

  test "missing operations, missing configuration, and unexpected results fail closed" do
    authorization = authorization()
    command = invited_user_command(authorization)

    Application.put_env(
      :comms_core,
      :tenant_invitation_identity_adapter,
      MissingOperationAdapter
    )

    assert {:ok, :checked} =
             Repo.transaction(fn ->
               assert :ok = InvitationIdentityPort.authorize_invitation(authorization)

               assert {:error, :identity_owner_unavailable} =
                        InvitationIdentityPort.validate_invitation_password(command.password)

               :checked
             end)

    Application.delete_env(:comms_core, :tenant_invitation_identity_adapter)

    assert {:ok, :checked} =
             Repo.transaction(fn ->
               assert {:error, :identity_owner_unavailable} =
                        InvitationIdentityPort.authorize_invitation(authorization)

               :checked
             end)

    Application.put_env(
      :comms_core,
      :tenant_invitation_identity_adapter,
      UnexpectedAdapter
    )

    assert {:ok, :checked} =
             Repo.transaction(fn ->
               assert {:error, :identity_owner_unavailable} =
                        InvitationIdentityPort.authorize_invitation(authorization)

               assert {:error, :identity_owner_unavailable} =
                        InvitationIdentityPort.validate_invitation_password(command.password)

               assert {:error, :identity_owner_unavailable} =
                        InvitationIdentityPort.ensure_invitation_identity_available(
                          command.tenant_id,
                          command.email
                        )

               assert {:error, :identity_owner_unavailable} =
                        InvitationIdentityPort.enroll_invited_user(command)

               :checked
             end)
  end

  test "enrollment rejects every mismatched or malformed receipt field" do
    authorization = authorization()
    command = invited_user_command(authorization)

    mutations = [
      &%{&1 | id: "not-a-uuid"},
      &%{&1 | tenant_id: Ecto.UUID.generate()},
      &%{&1 | display_name: "Different person"},
      &%{&1 | email: "different@example.test"},
      &%{&1 | account_type: :service},
      &%{&1 | role: :admin},
      &%{&1 | status: :suspended},
      &%{&1 | version: 0}
    ]

    assert {:ok, :rejected} =
             Repo.transaction(fn ->
               Enum.each(mutations, fn mutation ->
                 Process.put(:invited_identity_receipt_mutation, mutation)

                 assert {:error, :identity_owner_unavailable} =
                          InvitationIdentityPort.enroll_invited_user(command)
               end)

               Process.delete(:invited_identity_receipt_mutation)
               :rejected
             end)
  end

  test "invalid contract shapes are rejected without invoking an adapter" do
    assert {:error, :invalid_invitation_identity_authorization} =
             InvitationIdentityPort.authorize_invitation(%{})

    assert {:error, :invalid_invitation_identity} =
             InvitationIdentityPort.ensure_invitation_identity_available(nil, nil)

    assert {:error, :invalid_invited_user_command} =
             InvitationIdentityPort.enroll_invited_user(%{})

    refute_received {:authorize_invitation, _authorization}
    refute_received {:ensure_invitation_identity_available, _tenant_id, _email}
    refute_received {:enroll_invited_user, _command}
  end

  test "the enrollment command redacts its password from inspection" do
    command = invited_user_command(authorization())
    inspected = inspect(command)

    refute inspected =~ command.password
    refute inspected =~ "password:"
    assert inspected =~ "InvitedUserCommand"
  end

  defp authorization do
    %InvitationIdentityAuthorization{
      tenant_id: Ecto.UUID.generate(),
      actor_user_id: Ecto.UUID.generate(),
      email: "invited@example.test",
      role: :moderator
    }
  end

  defp invited_user_command(authorization) do
    %InvitedUserCommand{
      tenant_id: authorization.tenant_id,
      email: authorization.email,
      display_name: "Invited user",
      role: authorization.role,
      password: "correct-horse-invitation-port",
      admission_policy: %AdmissionPolicy{
        max_active_users: 100,
        max_active_conversations: 100,
        max_conversation_members: 100
      }
    }
  end
end
