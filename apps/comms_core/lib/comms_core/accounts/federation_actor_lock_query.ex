defmodule CommsCore.Accounts.FederationActorLockQuery do
  @moduledoc "Exact current actor plus bounded sorted local federation principals on the caller transaction."
  @enforce_keys [:subject, :local_participant_user_ids, :deadline]
  defstruct [:subject, :local_participant_user_ids, :deadline]

  @type t :: %__MODULE__{
          subject: map(),
          local_participant_user_ids: [binary()],
          deadline: integer()
        }
end
