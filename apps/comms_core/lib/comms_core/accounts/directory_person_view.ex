defmodule CommsCore.Accounts.DirectoryPersonView do
  @moduledoc """
  Privacy-minimal active-human identity projection for the member directory.

  Email, tenant role, lifecycle state, and persistence metadata are
  intentionally excluded. Eligibility is established by IdentityAccess before
  this projection is returned.
  """

  @enforce_keys [:id, :display_name]
  defstruct [:id, :display_name]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          display_name: String.t()
        }
end
