defmodule CommsCore.SharedDocuments.SummaryView do
  @moduledoc "Bounded document discovery projection without retained atoms or edit content."
  defstruct [
    :id,
    :conversation_id,
    :title,
    :excerpt,
    :generation,
    :version,
    :updated_at,
    readonly: false
  ]

  @type t :: %__MODULE__{
          id: binary(),
          conversation_id: binary(),
          title: binary(),
          excerpt: binary(),
          generation: pos_integer(),
          version: non_neg_integer(),
          updated_at: DateTime.t(),
          readonly: boolean()
        }
end
