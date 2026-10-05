defmodule CommsCore.Messaging.DraftView do
  @moduledoc "Versioned user-private message composition, scoped to a current conversation membership."
  @enforce_keys [:conversation_id, :thread_key, :body, :version]
  defstruct @enforce_keys ++ [:expires_at]

  @type t :: %__MODULE__{
          conversation_id: binary(),
          thread_key: binary(),
          body: binary(),
          version: non_neg_integer(),
          expires_at: DateTime.t() | nil
        }
end
