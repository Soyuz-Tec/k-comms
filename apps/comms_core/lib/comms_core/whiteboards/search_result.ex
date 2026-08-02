defmodule CommsCore.Whiteboards.SearchResult do
  @moduledoc "Authorized whiteboard text match returned without exposing operation payloads."

  @enforce_keys [:conversation_id, :element_id, :sequence, :text, :inserted_at]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          conversation_id: Ecto.UUID.t(),
          element_id: String.t(),
          sequence: pos_integer(),
          text: String.t(),
          inserted_at: DateTime.t()
        }
end
