defmodule CommsCore.Administration.InvitationIdentityPort do
  @moduledoc """
  TenantAdministration-owned port for transaction-scoped invitation identity effects.

  The configured IdentityAccess provider executes on the caller's active
  repository connection. Every operation fails closed outside a transaction,
  when the provider is unavailable, or when enrollment returns a receipt that
  does not correspond exactly to the submitted command.
  """

  alias CommsCore.Administration.{
    AdmissionPolicy,
    InvitationIdentityAuthorization,
    InvitedIdentityReceipt,
    InvitedUserCommand
  }

  alias CommsCore.Repo

  @unavailable {:error, :identity_owner_unavailable}
  @roles [:member, :moderator, :admin, :compliance_admin, :security_admin]

  @callback authorize_invitation(InvitationIdentityAuthorization.t()) ::
              :ok | {:error, term()}

  @callback validate_invitation_password(term()) :: :ok | {:error, term()}

  @callback ensure_invitation_identity_available(Ecto.UUID.t(), String.t()) ::
              :ok | {:error, term()}

  @callback enroll_invited_user(InvitedUserCommand.t()) ::
              {:ok, InvitedIdentityReceipt.t()} | {:error, term()}

  @spec authorize_invitation(InvitationIdentityAuthorization.t()) ::
          :ok | {:error, term()}
  def authorize_invitation(%InvitationIdentityAuthorization{} = authorization) do
    if Repo.in_transaction?() do
      :authorize_invitation
      |> dispatch([authorization])
      |> validate_unit_result()
    else
      {:error, :transaction_required}
    end
  end

  def authorize_invitation(_authorization),
    do: {:error, :invalid_invitation_identity_authorization}

  @spec validate_invitation_password(term()) :: :ok | {:error, term()}
  def validate_invitation_password(password) do
    if Repo.in_transaction?() do
      :validate_invitation_password
      |> dispatch([password])
      |> validate_unit_result()
    else
      {:error, :transaction_required}
    end
  end

  @spec ensure_invitation_identity_available(Ecto.UUID.t(), String.t()) ::
          :ok | {:error, term()}
  def ensure_invitation_identity_available(tenant_id, email)
      when is_binary(tenant_id) and is_binary(email) do
    if Repo.in_transaction?() do
      :ensure_invitation_identity_available
      |> dispatch([tenant_id, email])
      |> validate_unit_result()
    else
      {:error, :transaction_required}
    end
  end

  def ensure_invitation_identity_available(_tenant_id, _email),
    do: {:error, :invalid_invitation_identity}

  @spec enroll_invited_user(InvitedUserCommand.t()) ::
          {:ok, InvitedIdentityReceipt.t()} | {:error, term()}
  def enroll_invited_user(%InvitedUserCommand{} = command) do
    if Repo.in_transaction?() do
      if valid_command?(command) do
        :enroll_invited_user
        |> dispatch([command])
        |> validate_enrollment_result(command)
      else
        {:error, :invalid_invited_user_command}
      end
    else
      {:error, :transaction_required}
    end
  end

  def enroll_invited_user(_command), do: {:error, :invalid_invited_user_command}

  defp dispatch(operation, args) do
    with {:ok, adapter} <-
           Application.fetch_env(:comms_core, :tenant_invitation_identity_adapter),
         true <- is_atom(adapter) and Code.ensure_loaded?(adapter),
         true <- function_exported?(adapter, operation, length(args)) do
      apply(adapter, operation, args)
    else
      _ -> @unavailable
    end
  end

  defp validate_unit_result(:ok), do: :ok
  defp validate_unit_result({:error, _reason} = error), do: error
  defp validate_unit_result(_invalid_result), do: @unavailable

  defp validate_enrollment_result(
         {:ok, %InvitedIdentityReceipt{} = receipt},
         %InvitedUserCommand{} = command
       ) do
    if valid_receipt?(receipt, command), do: {:ok, receipt}, else: @unavailable
  end

  defp validate_enrollment_result({:error, _reason} = error, _command), do: error
  defp validate_enrollment_result(_invalid_result, _command), do: @unavailable

  defp valid_receipt?(receipt, command) do
    valid_uuid?(receipt.id) and
      receipt.tenant_id == command.tenant_id and
      valid_uuid?(receipt.tenant_id) and
      normalized_email(receipt.email) == normalized_email(command.email) and
      receipt.display_name == command.display_name and
      receipt.account_type == :human and
      receipt.role == command.role and
      receipt.status == :active and
      is_integer(receipt.version) and receipt.version > 0
  end

  defp valid_command?(%InvitedUserCommand{} = command) do
    valid_uuid?(command.tenant_id) and
      is_binary(command.email) and String.trim(command.email) != "" and
      (is_nil(command.display_name) or is_binary(command.display_name)) and
      command.role in @roles and is_binary(command.password) and
      match?(%AdmissionPolicy{}, command.admission_policy)
  end

  defp normalized_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  defp normalized_email(_email), do: nil

  defp valid_uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))
end
