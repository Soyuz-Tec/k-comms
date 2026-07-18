defmodule CommsCore.Administration.InvitationView do
  @moduledoc "Stable tenant-invitation projection."
  defstruct [
    :id,
    :email,
    :role,
    :status,
    :invited_by_user_id,
    :accepted_user_id,
    :expires_at,
    :accepted_at,
    :revoked_at,
    :version,
    :inserted_at
  ]
end
