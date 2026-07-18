defmodule CommsCore.Attachments.RestoreContext do
  @moduledoc """
  Audit context required for a one-shot restored-attachment remap.
  """

  @enforce_keys [:operation_id, :actor, :reason]
  defstruct [:operation_id, :actor, :reason]

  @type t :: %__MODULE__{
          operation_id: String.t(),
          actor: String.t(),
          reason: String.t()
        }
end
