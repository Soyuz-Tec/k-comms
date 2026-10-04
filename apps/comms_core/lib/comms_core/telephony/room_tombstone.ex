defmodule CommsCore.Telephony.RoomTombstone do
  @moduledoc false
  use CommsCore.Schema

  schema "telephony_room_tombstones" do
    field(:room_hash, :string)
    field(:expires_at, :utc_datetime_usec)
    timestamps()
  end

  def changeset(tombstone, attrs) do
    tombstone
    |> cast(attrs, [:room_hash, :expires_at])
    |> validate_required([:room_hash, :expires_at])
    |> unique_constraint(:room_hash)
  end
end
