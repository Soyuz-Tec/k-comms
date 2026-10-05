defmodule CommsCore.Conversations.PrivateRoomProtectionPort do
  @moduledoc "Conversations-owned retained Governance projection. Acquired before identity or room resources."
  alias CommsCore.Conversations.PrivateRoomProtection

  @callback protection(binary(), binary(), [binary()]) ::
              {:ok, PrivateRoomProtection.t()} | {:error, atom()}
  def protection(tenant, room, users) do
    if CommsCore.Repo.in_transaction?() do
      with {:ok, adapter} <- Application.fetch_env(:comms_core, :private_room_protection_adapter),
           {:ok, %PrivateRoomProtection{held: held, capture_blocked: blocked} = value} <-
             adapter.protection(tenant, room, users),
           true <- is_boolean(held) and is_boolean(blocked) do
        {:ok, value}
      else
        _ -> {:error, :private_room_protection_unavailable}
      end
    else
      {:error, :transaction_required}
    end
  end
end
