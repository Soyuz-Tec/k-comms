defmodule CommsCore.SharedDocuments.DocumentView do
  @moduledoc "Current authorized plaintext document projection; lineage remains owner-private."
  defstruct [
    :id,
    :conversation_id,
    :title,
    :content,
    :generation,
    :version,
    :updated_at,
    atoms: [],
    readonly: false
  ]

  @type atom_view :: %{
          required(:id) => binary(),
          required(:after_id) => binary() | nil,
          required(:text) => binary(),
          required(:deleted) => boolean(),
          required(:order) => non_neg_integer()
        }
  @type t :: %__MODULE__{
          id: binary(),
          conversation_id: binary(),
          title: binary(),
          content: binary(),
          generation: pos_integer(),
          version: non_neg_integer(),
          updated_at: DateTime.t(),
          atoms: [atom_view()],
          readonly: boolean()
        }
end
