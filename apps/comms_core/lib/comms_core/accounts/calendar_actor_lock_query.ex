defmodule CommsCore.Accounts.CalendarActorLockQuery do
  @moduledoc "Exact interactive calendar actor; never inferred from role alone."
  @enforce_keys [:subject, :deadline_ms, :require_step_up?]
  defstruct [:subject, :deadline_ms, :require_step_up?, purpose: :export]

  @type t :: %__MODULE__{
          subject: map(),
          deadline_ms: integer(),
          require_step_up?: boolean(),
          purpose: :export | :cleanup
        }
end
