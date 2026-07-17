defmodule CommsCore.Accounts.ConversationBootstrapPort do
  @moduledoc """
  IdentityAccess-owned port for the transaction-scoped initial conversation.

  The configured Conversations owner executes commands on the caller's active
  repository connection. The composition-root binding is deliberately narrow:
  it supports only initial-channel creation and idempotent bootstrap lookup.
  """

  alias CommsCore.Accounts.{InitialConversationCommand, InitialConversationReceipt}
  alias CommsCore.Repo

  @callback create_initial_channel(InitialConversationCommand.t()) ::
              {:ok, InitialConversationReceipt.t()} | {:error, term()}

  @callback fetch_initial_channel(binary(), binary()) ::
              {:ok, InitialConversationReceipt.t() | nil} | {:error, term()}

  @spec append_initial_channel(
          Ecto.Multi.t(),
          atom(),
          InitialConversationCommand.t()
        ) :: Ecto.Multi.t()
  def append_initial_channel(multi, operation, %InitialConversationCommand{} = command)
      when is_atom(operation) do
    Ecto.Multi.run(multi, operation, fn _repo, _changes ->
      create_initial_channel(command)
    end)
  end

  @spec create_initial_channel(InitialConversationCommand.t()) ::
          {:ok, InitialConversationReceipt.t()} | {:error, term()}
  def create_initial_channel(%InitialConversationCommand{} = command) do
    if Repo.in_transaction?() do
      :create_initial_channel
      |> dispatch([command])
      |> validate_created_receipt(command)
    else
      {:error, :transaction_required}
    end
  end

  @spec fetch_initial_channel(binary(), binary()) ::
          {:ok, InitialConversationReceipt.t() | nil} | {:error, term()}
  def fetch_initial_channel(tenant_id, owner_user_id)
      when is_binary(tenant_id) and is_binary(owner_user_id) do
    if Repo.in_transaction?() do
      :fetch_initial_channel
      |> dispatch([tenant_id, owner_user_id])
      |> validate_fetched_receipt(tenant_id, owner_user_id)
    else
      {:error, :transaction_required}
    end
  end

  def fetch_initial_channel(_tenant_id, _owner_user_id),
    do: {:error, :initial_conversation_not_found}

  defp dispatch(operation, args) do
    with {:ok, adapter} <-
           Application.fetch_env(:comms_core, :identity_conversation_bootstrap_adapter),
         true <- is_atom(adapter) and Code.ensure_loaded?(adapter),
         true <- function_exported?(adapter, operation, length(args)) do
      apply(adapter, operation, args)
    else
      _ -> {:error, :conversation_owner_unavailable}
    end
  end

  defp validate_created_receipt(
         {:ok, %InitialConversationReceipt{} = receipt},
         %InitialConversationCommand{} = command
       ) do
    if valid_receipt?(receipt) and receipt.id == command.id and
         receipt.tenant_id == command.tenant_id and
         receipt.owner_user_id == command.owner_user_id do
      {:ok, receipt}
    else
      {:error, :conversation_owner_unavailable}
    end
  end

  defp validate_created_receipt({:error, _reason} = error, _command), do: error

  defp validate_created_receipt(_invalid_result, _command),
    do: {:error, :conversation_owner_unavailable}

  defp validate_fetched_receipt({:ok, nil}, _tenant_id, _owner_user_id), do: {:ok, nil}

  defp validate_fetched_receipt(
         {:ok, %InitialConversationReceipt{} = receipt},
         tenant_id,
         owner_user_id
       ) do
    if valid_receipt?(receipt) and receipt.tenant_id == tenant_id and
         receipt.owner_user_id == owner_user_id do
      {:ok, receipt}
    else
      {:error, :conversation_owner_unavailable}
    end
  end

  defp validate_fetched_receipt({:error, _reason} = error, _tenant_id, _owner_user_id),
    do: error

  defp validate_fetched_receipt(_invalid_result, _tenant_id, _owner_user_id),
    do: {:error, :conversation_owner_unavailable}

  defp valid_receipt?(%InitialConversationReceipt{} = receipt) do
    valid_uuid?(receipt.id) and valid_uuid?(receipt.tenant_id) and
      valid_uuid?(receipt.owner_user_id) and receipt.kind == :channel and
      receipt.title == "General" and receipt.visibility == :tenant and
      is_integer(receipt.latest_sequence) and receipt.latest_sequence >= 0 and
      is_nil(receipt.archived_at) and is_integer(receipt.version) and receipt.version > 0 and
      match?(%DateTime{}, receipt.inserted_at) and match?(%DateTime{}, receipt.updated_at)
  end

  defp valid_uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
end
