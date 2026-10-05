defmodule CommsCore.Accounts.CalendarSourceGrant do
  @moduledoc "A limited human may edit an eligible meeting without acquiring calendar export permission."
  @enforce_keys [:actor, :eligible_export_user_ids]
  defstruct [:actor, :eligible_export_user_ids]
  @type t :: %__MODULE__{actor: CommsCore.Accounts.AccessGrant.t(), eligible_export_user_ids: [binary()]}
end
