defmodule CommsCore.CallLifecyclePortsTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts.{
    CallLifecycleCommand,
    CallLifecyclePort,
    CallLifecycleReceipt
  }

  alias CommsCore.Administration, as: TenantAdministration
  alias CommsCore.Conversations

  defmodule IdentitySuccessAdapter do
    @behaviour CommsCore.Accounts.CallLifecyclePort

    @impl true
    def revoke_identity_access(%CommsCore.Accounts.CallLifecycleCommand{}),
      do:
        {:ok,
         %CommsCore.Accounts.CallLifecycleReceipt{
           revoked_participant_count: 0
         }}
  end

  defmodule TenantSuccessAdapter do
    @behaviour CommsCore.Administration.CallLifecyclePort

    @impl true
    def revoke_tenant_media(%CommsCore.Administration.CallLifecycleCommand{}),
      do:
        {:ok,
         %CommsCore.Administration.CallLifecycleReceipt{
           revoked_participant_count: 0
         }}
  end

  defmodule ConversationSuccessAdapter do
    @behaviour CommsCore.Conversations.CallLifecyclePort

    @impl true
    def revoke_conversation_access(%CommsCore.Conversations.CallLifecycleCommand{}),
      do:
        {:ok,
         %CommsCore.Conversations.CallLifecycleReceipt{
           revoked_participant_count: 0
         }}
  end

  defmodule InvalidReceiptAdapter do
    @behaviour CommsCore.Accounts.CallLifecyclePort

    @impl true
    def revoke_identity_access(%CommsCore.Accounts.CallLifecycleCommand{}),
      do: {:ok, :invalid_receipt}
  end

  setup do
    bindings = [
      identity_call_lifecycle_adapter: IdentitySuccessAdapter,
      tenant_call_lifecycle_adapter: TenantSuccessAdapter,
      conversation_call_lifecycle_adapter: ConversationSuccessAdapter
    ]

    previous =
      Map.new(bindings, fn {key, _adapter} ->
        {key, Application.fetch_env(:comms_core, key)}
      end)

    Enum.each(bindings, fn {key, adapter} ->
      Application.put_env(:comms_core, key, adapter)
    end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, adapter}} -> Application.put_env(:comms_core, key, adapter)
        {key, :error} -> Application.delete_env(:comms_core, key)
      end)
    end)

    :ok
  end

  test "identity commands require the caller transaction and return an Ecto-free receipt" do
    tenant_id = Ecto.UUID.generate()
    session_id = Ecto.UUID.generate()
    command = CallLifecycleCommand.sessions_revoked(tenant_id, [session_id], "session_revoked")

    assert {:error, :transaction_required} =
             CallLifecyclePort.revoke_identity_access(command)

    assert {:ok, {:ok, %CallLifecycleReceipt{revoked_participant_count: 0}}} =
             Repo.transaction(fn -> CallLifecyclePort.revoke_identity_access(command) end)
  end

  test "tenant and conversation commands use exact transaction-required adapters" do
    tenant_id = Ecto.UUID.generate()
    conversation_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()

    tenant_command =
      TenantAdministration.CallLifecycleCommand.tenant_media_disabled(
        tenant_id,
        :audio,
        "tenant_audio_disabled"
      )

    membership_command =
      Conversations.CallLifecycleCommand.membership_revoked(
        tenant_id,
        conversation_id,
        user_id,
        "membership_left"
      )

    archive_command =
      Conversations.CallLifecycleCommand.conversation_archived(
        tenant_id,
        conversation_id,
        "conversation_archived"
      )

    assert {:error, :transaction_required} =
             TenantAdministration.CallLifecyclePort.revoke_tenant_media(tenant_command)

    assert {:error, :transaction_required} =
             Conversations.CallLifecyclePort.revoke_conversation_access(membership_command)

    assert {:ok,
            {
              {:ok,
               %TenantAdministration.CallLifecycleReceipt{
                 revoked_participant_count: 0
               }},
              {:ok, %Conversations.CallLifecycleReceipt{revoked_participant_count: 0}},
              {:ok, %Conversations.CallLifecycleReceipt{revoked_participant_count: 0}}
            }} =
             Repo.transaction(fn ->
               {
                 TenantAdministration.CallLifecyclePort.revoke_tenant_media(tenant_command),
                 Conversations.CallLifecyclePort.revoke_conversation_access(membership_command),
                 Conversations.CallLifecyclePort.revoke_conversation_access(archive_command)
               }
             end)
  end

  test "ports reject malformed commands and malformed adapter receipts" do
    tenant_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()

    invalid_command =
      CallLifecycleCommand.user_access_revoked(tenant_id, user_id, "password_recovery")
      |> Map.put(:reason, "")

    assert {:ok, {:error, :invalid_call_lifecycle_command}} =
             Repo.transaction(fn -> CallLifecyclePort.revoke_identity_access(invalid_command) end)

    Application.put_env(
      :comms_core,
      :identity_call_lifecycle_adapter,
      InvalidReceiptAdapter
    )

    valid_command =
      CallLifecycleCommand.user_access_revoked(tenant_id, user_id, "password_recovery")

    assert {:ok, {:error, :call_lifecycle_unavailable}} =
             Repo.transaction(fn -> CallLifecyclePort.revoke_identity_access(valid_command) end)
  end
end
