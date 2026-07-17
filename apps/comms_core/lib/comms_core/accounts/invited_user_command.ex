defmodule CommsCore.Accounts.InvitedUserCommand do
  @moduledoc """
  Persistence-neutral command used to enroll a human identity from an invitation.
  """

  @derive {Inspect, except: [:password]}
  @enforce_keys [:tenant_id, :email, :role, :password]
  defstruct [:tenant_id, :email, :display_name, :role, :password]
end
