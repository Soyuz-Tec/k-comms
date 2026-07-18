defmodule CommsCore.Administration.AdmissionPolicy do
  @moduledoc """
  Ecto-free tenant admission limits consumed by resource owners.
  """

  @enforce_keys [
    :max_active_users,
    :max_active_conversations,
    :max_conversation_members
  ]
  defstruct [
    :max_active_users,
    :max_active_conversations,
    :max_conversation_members
  ]

  @type t :: %__MODULE__{
          max_active_users: pos_integer(),
          max_active_conversations: pos_integer(),
          max_conversation_members: pos_integer()
        }
end
