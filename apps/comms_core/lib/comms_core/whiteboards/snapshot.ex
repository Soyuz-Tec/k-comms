defmodule CommsCore.Whiteboards.Snapshot do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "whiteboard_snapshots" do
    field(:whiteboard_id, Ecto.UUID)
    field(:tenant_id, Ecto.UUID)
    field(:conversation_id, Ecto.UUID)
    field(:through_sequence, :integer)
    field(:generation_sequence, :integer, default: 0)
    field(:elements, :map, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  @castable [
    :whiteboard_id,
    :tenant_id,
    :conversation_id,
    :through_sequence,
    :generation_sequence,
    :elements
  ]

  @type t :: %__MODULE__{}

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, @castable)
    |> validate_required([
      :whiteboard_id,
      :tenant_id,
      :conversation_id,
      :through_sequence,
      :elements
    ])
    |> validate_number(:through_sequence, greater_than: 0)
    |> validate_number(:generation_sequence, greater_than_or_equal_to: 0)
    |> unique_constraint(:whiteboard_id, name: :whiteboard_snapshots_board_unique)
  end
end
