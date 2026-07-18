defmodule CommsCore.Operations.TenantQuotaUsage do
  @moduledoc """
  Ecto-free administrative projection of tenant admission capacity.
  """

  @enforce_keys [
    :active_users,
    :active_conversations,
    :largest_conversation_members,
    :limits,
    :at_capacity,
    :over_limit
  ]
  defstruct [
    :active_users,
    :active_conversations,
    :largest_conversation_members,
    :limits,
    :at_capacity,
    :over_limit
  ]

  @type capacity_flags :: %{
          required(:active_users) => boolean(),
          required(:active_conversations) => boolean(),
          required(:conversation_members) => boolean(),
          required(:any) => boolean()
        }

  @type t :: %__MODULE__{
          active_users: non_neg_integer(),
          active_conversations: non_neg_integer(),
          largest_conversation_members: non_neg_integer(),
          limits: %{
            required(:max_active_users) => pos_integer(),
            required(:max_active_conversations) => pos_integer(),
            required(:max_conversation_members) => pos_integer()
          },
          at_capacity: capacity_flags(),
          over_limit: capacity_flags()
        }
end
