defmodule CommsCore.Messaging.MessageDeliveryCursor do
  @moduledoc false

  use CommsCore.Schema

  schema "message_delivery_cursors" do
    field(:tenant_id, :binary_id)
    field(:conversation_id, :binary_id)
    field(:user_id, :binary_id)
    field(:device_id, :binary_id)
    field(:delivered_sequence, :integer, default: 0)
    field(:read_sequence, :integer, default: 0)
    field(:delivered_at, :utc_datetime_usec)
    field(:read_at, :utc_datetime_usec)
    timestamps()
  end

  def changeset(cursor, attrs) do
    cursor
    |> cast(attrs, [
      :tenant_id,
      :conversation_id,
      :user_id,
      :device_id,
      :delivered_sequence,
      :read_sequence,
      :delivered_at,
      :read_at
    ])
    |> validate_required([
      :tenant_id,
      :conversation_id,
      :user_id,
      :device_id,
      :delivered_sequence,
      :read_sequence
    ])
    |> validate_number(:delivered_sequence, greater_than_or_equal_to: 0)
    |> validate_number(:read_sequence, greater_than_or_equal_to: 0)
    |> unique_constraint([:tenant_id, :conversation_id, :user_id, :device_id],
      name: :message_delivery_cursors_identity_unique
    )
    |> check_constraint(:read_sequence, name: :message_delivery_cursors_valid_sequences)
  end
end
