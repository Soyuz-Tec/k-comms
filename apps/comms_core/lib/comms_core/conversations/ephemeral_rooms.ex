defmodule CommsCore.Conversations.EphemeralRooms do
  @moduledoc false

  alias CommsCore.{Repo, RuntimePorts}

  alias CommsCore.Conversations.{
    CallLifecycleCommand,
    CallLifecyclePort,
    CallLifecycleReceipt,
    EphemeralJoinReceipt,
    EphemeralPresenceLease,
    EphemeralRoom,
    EphemeralRoomView
  }

  alias CommsCore.Conversations.EphemeralRooms.{
    Admission,
    Authority,
    ConversionHooks,
    Creation,
    Lifecycle,
    Presence
  }

  @spec create(map(), :guest | map()) :: {:ok, map()} | {:error, term()}
  defdelegate create(attrs, creator), to: Creation

  @spec preview(String.t()) ::
          {:ok,
           %{
             room_id: Ecto.UUID.t(),
             room_title: String.t(),
             status: :active | :idle,
             expires_at: DateTime.t() | nil,
             participant_limit: pos_integer()
           }}
          | {:error, :ephemeral_room_unavailable}
  defdelegate preview(token), to: Admission

  @spec join(String.t(), map(), :guest | map()) :: {:ok, map()} | {:error, term()}
  defdelegate join(token, attrs, joiner), to: Admission

  @spec open_presence(map()) :: {:ok, map()} | {:error, term()}
  defdelegate open_presence(attrs), to: Presence, as: :open

  @spec heartbeat_presence(map()) :: {:ok, map()} | {:error, term()}
  defdelegate heartbeat_presence(attrs), to: Presence, as: :heartbeat

  @spec close_presence(map()) :: {:ok, map()} | {:error, term()}
  defdelegate close_presence(attrs), to: Presence, as: :close

  @spec room_for_conversation(Ecto.UUID.t(), map()) ::
          {:ok, EphemeralRoomView.t() | nil} | {:error, :forbidden}
  defdelegate room_for_conversation(conversation_id, subject), to: Authority

  @spec reconcile(Ecto.UUID.t(), pos_integer(), module()) ::
          {:ok,
           :active
           | :already_terminal
           | :stale_generation
           | {:idle, DateTime.t(), pos_integer()}}
          | {:error, term()}
  def reconcile(room_id, expected_generation, caller)
      when is_binary(room_id) and is_integer(expected_generation) and expected_generation > 0 do
    if RuntimePorts.authorized_job_worker?(:ephemeral_room_reconciler, caller) do
      Lifecycle.reconcile(room_id, expected_generation)
    else
      {:error, :forbidden}
    end
  end

  def reconcile(_room_id, _expected_generation, _caller), do: {:error, :forbidden}

  @spec reconcile_all(module()) ::
          {:ok, %{scanned: non_neg_integer(), reconciled: non_neg_integer()}}
          | {:error, :forbidden}
  def reconcile_all(caller) do
    if RuntimePorts.authorized_job_worker?(:ephemeral_room_reconciler, caller) do
      Lifecycle.reconcile_all(fn room_id, generation ->
        reconcile(room_id, generation, caller)
      end)
    else
      {:error, :forbidden}
    end
  end

  @spec expire(Ecto.UUID.t(), pos_integer(), module(), function()) ::
          {:ok,
           :expired | :already_terminal | :active | :stale_generation | {:not_due, pos_integer()}}
          | {:error, term()}
  def expire(room_id, expected_generation, caller, call_access_revoker)
      when is_binary(room_id) and is_integer(expected_generation) and expected_generation > 0 and
             is_function(call_access_revoker, 4) do
    if RuntimePorts.authorized_job_worker?(:ephemeral_room_lifecycle, caller) do
      Lifecycle.expire(
        room_id,
        expected_generation,
        call_access_revoker,
        &revoke_archived_conversation_access/3
      )
    else
      {:error, :forbidden}
    end
  end

  def expire(_room_id, _expected_generation, _caller, _call_access_revoker),
    do: {:error, :forbidden}

  def persisted_room_count, do: Repo.aggregate(EphemeralRoom, :count)
  def persisted_presence_lease_count, do: Repo.aggregate(EphemeralPresenceLease, :count)
  def persisted_join_receipt_count, do: Repo.aggregate(EphemeralJoinReceipt, :count)

  @doc false
  defdelegate lock_conversion_room(link), to: ConversionHooks

  @doc false
  defdelegate upgrade_converted_owner(room, authentication, timestamp, request_id),
    to: ConversionHooks

  @doc false
  defdelegate handoff_converted_presence(room, old_session_id, authentication, timestamp),
    to: ConversionHooks

  @doc false
  defdelegate close_logged_out_presence(room, user_id, session_id, timestamp),
    to: ConversionHooks

  defp revoke_archived_conversation_access(tenant_id, conversation_id, reason) do
    case tenant_id
         |> CallLifecycleCommand.conversation_archived(conversation_id, reason)
         |> CallLifecyclePort.revoke_conversation_access() do
      {:ok, %CallLifecycleReceipt{}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
