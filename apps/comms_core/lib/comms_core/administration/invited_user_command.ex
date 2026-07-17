defmodule CommsCore.Administration.InvitedUserCommand do
  @moduledoc """
  Persistence-free command for enrolling the human identity accepted by an invitation.

  The password is deliberately redacted from inspection because this command
  crosses the runtime collaboration boundary in the caller's transaction.
  """

  @derive {Inspect, except: [:password]}
  alias CommsCore.Administration.AdmissionPolicy

  @enforce_keys [:tenant_id, :email, :role, :password, :admission_policy]
  defstruct [:tenant_id, :email, :display_name, :role, :password, :admission_policy]

  @type t :: %__MODULE__{
          tenant_id: Ecto.UUID.t(),
          email: String.t(),
          display_name: String.t() | nil,
          role: atom(),
          password: String.t(),
          admission_policy: AdmissionPolicy.t()
        }
end
