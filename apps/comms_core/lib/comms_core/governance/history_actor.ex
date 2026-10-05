defmodule CommsCore.Governance.HistoryActor do
  @moduledoc "Current tenant-scoped actor projection for retained lifecycle evidence."
  @enforce_keys [:kind]
  defstruct [:kind, :user_id, :display_name]

  @type t :: %__MODULE__{
          kind: :user | :system | :unavailable,
          user_id: Ecto.UUID.t() | nil,
          display_name: String.t() | nil
        }
end
