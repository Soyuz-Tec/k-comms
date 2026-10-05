defmodule CommsCore.Telephony.IvrConfigView do
  @moduledoc "Current administrator IVR configuration and qualified capability projection."
  @type t :: %{
          menu: CommsCore.Telephony.IvrMenuView.t() | nil,
          available: boolean(),
          max_active_callers: pos_integer(),
          approved_prompts: [String.t()]
        }
end
