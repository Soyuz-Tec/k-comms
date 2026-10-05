defmodule CommsCore.Whiteboards.VersionView do
  @moduledoc "Metadata for a named durable checkpoint; scene bytes require separate authorization."
  @enforce_keys [:id, :label, :through_sequence, :actor_user_id, :inserted_at]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: binary(),
          label: binary(),
          through_sequence: non_neg_integer(),
          actor_user_id: binary(),
          inserted_at: DateTime.t()
        }
end
