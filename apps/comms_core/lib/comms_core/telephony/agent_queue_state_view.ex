defmodule CommsCore.Telephony.AgentQueueStateView do
  @moduledoc "Own bounded queue eligibility state. This projection does not observe presence."
  @type t :: %{
          state: :ready | :away | :wrap_up,
          expires_at: DateTime.t() | nil,
          version: non_neg_integer(),
          explicit: boolean(),
          online_presence_observed: false
        }
end
