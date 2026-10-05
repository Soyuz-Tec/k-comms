defmodule CommsCore.Messaging.PrivateEvent do
  @moduledoc false
  use CommsCore.Schema

  schema "opaque_private_events" do
    field(:tenant_id, Ecto.UUID)
    field(:conversation_id, Ecto.UUID)
    field(:author_user_id, Ecto.UUID)
    field(:author_device_id, Ecto.UUID)
    field(:author_session_id, Ecto.UUID)
    field(:transaction_id, :string)
    field(:matrix_event_id, :string)
    field(:matrix_room_id, :string)
    field(:matrix_sender, :string)
    field(:membership_epoch, :integer)
    field(:generation, :integer)
    field(:sequence, :integer)
    field(:input_fingerprint, :binary)
    field(:content, :map)
    field(:state, Ecto.Enum, values: [:pending, :retained, :erased], default: :pending)
    field(:erased_at, :utc_datetime_usec)
    timestamps()
  end
end
