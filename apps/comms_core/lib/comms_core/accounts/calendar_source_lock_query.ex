defmodule CommsCore.Accounts.CalendarSourceLockQuery do
  @moduledoc "Current meeting editor plus sorted offline host principals."
  @enforce_keys [:subject, :connected_host_user_ids, :deadline_ms]
  defstruct [:subject, :connected_host_user_ids, :deadline_ms]
  @type t :: %__MODULE__{subject: map(), connected_host_user_ids: [binary()], deadline_ms: integer()}
end
