defmodule CommsCore.Accounts.Invitations do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Accounts.{Directory, User}

  alias CommsCore.Administration.{
    InvitationIdentityAuthorization,
    InvitedIdentityReceipt,
    InvitedUserCommand
  }

  alias CommsCore.Repo
  alias CommsCore.Security.Password

  @spec validate_password(String.t()) :: :ok | {:error, :transaction_required | :weak_password}
  def validate_password(password) do
    if Repo.in_transaction?(),
      do: validate_password_strength(password),
      else: {:error, :transaction_required}
  end

  @spec authorize(InvitationIdentityAuthorization.t()) ::
          :ok | {:error, :forbidden | :invalid_role | :transaction_required}
  def authorize(%InvitationIdentityAuthorization{} = authorization) do
    if Repo.in_transaction?() do
      subject = %{
        tenant_id: authorization.tenant_id,
        user_id: authorization.actor_user_id
      }

      with :ok <- reject_service_identity_email(authorization.tenant_id, authorization.email),
           :ok <- authorize_role_assignment(subject, authorization.role) do
        :ok
      end
    else
      {:error, :transaction_required}
    end
  end

  @spec ensure_identity_available(Ecto.UUID.t(), String.t()) ::
          :ok | {:error, :invitation_identity_conflict | :transaction_required}
  def ensure_identity_available(tenant_id, email)
      when is_binary(tenant_id) and is_binary(email) do
    if Repo.in_transaction?(),
      do: reject_existing_human_identity(tenant_id, email),
      else: {:error, :transaction_required}
  end

  @spec enroll(InvitedUserCommand.t()) ::
          {:ok, InvitedIdentityReceipt.t()}
          | {:error,
             :active_user_quota_exceeded
             | :invitation_identity_conflict
             | :quota_transaction_required
             | :transaction_required
             | Ecto.Changeset.t()}
  def enroll(%InvitedUserCommand{} = command) do
    if Repo.in_transaction?() do
      with :ok <- reject_existing_human_identity(command.tenant_id, command.email),
           :ok <-
             Directory.ensure_active_user_capacity(
               command.tenant_id,
               command.admission_policy
             ),
           {:ok, user} <-
             %User{id: Ecto.UUID.generate()}
             |> User.changeset(%{
               tenant_id: command.tenant_id,
               external_subject: "local:#{command.email}",
               display_name: command.display_name,
               email: command.email,
               password_hash: Password.hash(command.password),
               account_type: :human,
               role: command.role,
               status: :active
             })
             |> Repo.insert() do
        {:ok, invited_identity_receipt(user)}
      end
    else
      {:error, :transaction_required}
    end
  end

  defp invited_identity_receipt(%User{} = user) do
    %InvitedIdentityReceipt{
      id: user.id,
      tenant_id: user.tenant_id,
      display_name: user.display_name,
      email: user.email,
      account_type: user.account_type,
      role: user.role,
      status: user.status,
      version: user.lock_version
    }
  end

  defp validate_password_strength(password) do
    if Password.valid_password?(password), do: :ok, else: {:error, :weak_password}
  end

  defp authorize_role_assignment(subject, role)
       when role in [:member, :moderator, :admin, :compliance_admin, :security_admin] do
    case Repo.get_by(User,
           id: value(subject, :user_id),
           tenant_id: value(subject, :tenant_id),
           status: :active,
           access_scope: :workspace
         ) do
      %User{role: :owner} -> :ok
      %User{role: :admin} when role in [:member, :moderator] -> :ok
      _ -> {:error, :forbidden}
    end
  end

  defp authorize_role_assignment(_, _), do: {:error, :invalid_role}

  defp reject_service_identity_email(tenant_id, email) do
    service_identity? =
      Repo.exists?(
        from(user in User,
          where:
            user.tenant_id == ^tenant_id and user.account_type == :service and
              fragment("lower(?)", user.email) == ^String.downcase(email)
        )
      )

    if service_identity?, do: {:error, :forbidden}, else: :ok
  end

  defp reject_existing_human_identity(tenant_id, email) do
    existing_identity? =
      Repo.exists?(
        from(user in User,
          where:
            user.tenant_id == ^tenant_id and user.account_type == :human and
              fragment("lower(?)", user.email) == ^String.downcase(email)
        )
      )

    if existing_identity?, do: {:error, :invitation_identity_conflict}, else: :ok
  end

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
