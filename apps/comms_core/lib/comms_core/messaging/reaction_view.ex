defmodule CommsCore.Messaging.ReactionView do
  @moduledoc "Persistence-neutral message reaction projection."

  @enforce_keys [:id, :message_id, :user_id, :emoji]
  defstruct [:id, :message_id, :user_id, :emoji]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          message_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          emoji: String.t()
        }
end
