defmodule CommsCore.Whiteboards.BoardView do
  @moduledoc "Gallery projection authorized against current conversation access."
  @enforce_keys [:id, :conversation_id, :title, :sequence, :library_version, :updated_at]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: binary(),
          conversation_id: binary(),
          title: binary(),
          sequence: non_neg_integer(),
          library_version: pos_integer(),
          updated_at: DateTime.t()
        }
end
