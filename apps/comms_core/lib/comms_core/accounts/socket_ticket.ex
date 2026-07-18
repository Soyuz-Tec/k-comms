defmodule CommsCore.Accounts.SocketTicket do
  use CommsCore.Schema

  schema "socket_tickets" do
    field(:tenant_id, Ecto.UUID)
    belongs_to(:user, CommsCore.Accounts.User)
    belongs_to(:device, CommsCore.Accounts.Device)
    belongs_to(:session, CommsCore.Accounts.Session)
    field(:token_hash, :binary, redact: true)
    field(:expires_at, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)
    timestamps(updated_at: false)
  end

  def changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [
      :tenant_id,
      :user_id,
      :device_id,
      :session_id,
      :token_hash,
      :expires_at,
      :consumed_at
    ])
    |> validate_required([
      :tenant_id,
      :user_id,
      :device_id,
      :session_id,
      :token_hash,
      :expires_at
    ])
    |> unique_constraint(:token_hash)
  end
end
