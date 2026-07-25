defmodule CommsCore.Conversations.GuestLinkView do
  @moduledoc "Secret-free projection of a conversation guest link."

  defstruct [
    :id,
    :tenant_id,
    :conversation_id,
    :created_by_user_id,
    :expires_at,
    :max_uses,
    :use_count,
    :remaining_uses,
    :status,
    :conversion_enabled,
    :email_hint,
    :revoked_at,
    :version,
    :inserted_at
  ]

  @type status :: :active | :expired | :revoked | :exhausted

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          tenant_id: Ecto.UUID.t(),
          conversation_id: Ecto.UUID.t(),
          created_by_user_id: Ecto.UUID.t(),
          expires_at: DateTime.t(),
          max_uses: pos_integer(),
          use_count: non_neg_integer(),
          remaining_uses: non_neg_integer(),
          status: status(),
          conversion_enabled: boolean(),
          email_hint: String.t() | nil,
          revoked_at: DateTime.t() | nil,
          version: pos_integer(),
          inserted_at: DateTime.t()
        }
end
