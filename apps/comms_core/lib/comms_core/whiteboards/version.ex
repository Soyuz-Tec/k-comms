defmodule CommsCore.Whiteboards.Version do
  @moduledoc false
  use CommsCore.Schema

  schema "whiteboard_versions" do
    field(:tenant_id, Ecto.UUID)
    field(:whiteboard_id, Ecto.UUID)
    field(:conversation_id, Ecto.UUID)
    field(:actor_user_id, Ecto.UUID)
    field(:label, :string)
    field(:through_sequence, :integer)
    field(:elements, :map)
    field(:source_actor_user_ids, {:array, Ecto.UUID}, default: [])
    timestamps(updated_at: false)
  end
end
