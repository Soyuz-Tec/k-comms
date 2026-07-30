defmodule CommsCore.Notifications.IdentityLifecycle do
  @moduledoc false

  alias CommsCore.Accounts.{NotificationCommand, NotificationReceipt}
  alias CommsCore.Notifications.{Intents, PushSubscriptions}
  alias CommsCore.Repo

  @recovery_event_type "account.password_recovery.requested.v1"

  def execute(%NotificationCommand{operation: :password_recovery} = command) do
    with :ok <- require_transaction(),
         {:ok, intent} <-
           Intents.create(%{
             tenant_id: command.tenant_id,
             user_id: command.user_id,
             event_type: @recovery_event_type,
             channel: :email,
             destination: command.destination,
             idempotency_key: "password-recovery:#{command.recovery_request_id}",
             payload: %{"recovery_request_id" => command.recovery_request_id}
           }) do
      {:ok, %NotificationReceipt{id: intent.id}}
    end
  end

  def execute(%NotificationCommand{operation: :device_revoked} = command) do
    with :ok <- require_transaction() do
      PushSubscriptions.disable_for_device(
        command.tenant_id,
        command.user_id,
        command.device_id,
        command.reason
      )
    end
  end

  def execute(%NotificationCommand{operation: :user_access_revoked} = command) do
    with :ok <- require_transaction() do
      PushSubscriptions.disable_for_user(
        command.tenant_id,
        command.user_id,
        command.reason
      )
    end
  end

  def execute(%NotificationCommand{}), do: {:error, :unsupported_identity_notification_command}

  defp require_transaction do
    if Repo.in_transaction?(), do: :ok, else: {:error, :transaction_required}
  end
end
