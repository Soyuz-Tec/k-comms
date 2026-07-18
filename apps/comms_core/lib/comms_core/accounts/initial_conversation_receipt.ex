defmodule CommsCore.Accounts.InitialConversationReceipt do
  @moduledoc """
  Persistence-neutral result for the initial-conversation bootstrap use case.

  The receipt intentionally carries only scalar projection fields. A
  Conversations provider cannot return an Ecto schema (or any other opaque
  term) through the IdentityAccess boundary.
  """

  @enforce_keys [
    :id,
    :tenant_id,
    :owner_user_id,
    :kind,
    :title,
    :visibility,
    :latest_sequence,
    :version,
    :inserted_at,
    :updated_at
  ]
  defstruct [
    :id,
    :tenant_id,
    :owner_user_id,
    :kind,
    :title,
    :visibility,
    :latest_sequence,
    :archived_at,
    :version,
    :inserted_at,
    :updated_at
  ]

  @type t :: %__MODULE__{
          id: binary(),
          tenant_id: binary(),
          owner_user_id: binary(),
          kind: :channel,
          title: String.t(),
          visibility: :tenant,
          latest_sequence: non_neg_integer(),
          archived_at: DateTime.t() | nil,
          version: pos_integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
