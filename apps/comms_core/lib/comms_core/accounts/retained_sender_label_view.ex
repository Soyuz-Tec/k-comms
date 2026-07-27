defmodule CommsCore.Accounts.RetainedSenderLabelView do
  @moduledoc """
  Privacy-minimal display label for an author referenced by retained content.

  Eligibility is established by IdentityAccess from an already authorized,
  tenant-scoped message page. Lifecycle state, account type, email, role,
  expiry, and persistence metadata are intentionally excluded.
  """

  @enforce_keys [:id, :display_name, :redacted]
  defstruct [:id, :display_name, :redacted]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          display_name: String.t(),
          redacted: boolean()
        }
end
