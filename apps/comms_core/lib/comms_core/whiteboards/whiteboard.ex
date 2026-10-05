defmodule CommsCore.Whiteboards.Whiteboard do
  @moduledoc false

  use CommsCore.Schema

  schema "whiteboards" do
    field(:tenant_id, Ecto.UUID)
    field(:conversation_id, Ecto.UUID)
    field(:sequence, :integer, default: 0)
    field(:title, :string, default: "Untitled board")
    field(:library_version, :integer, default: 1)
    field(:title_actor_user_id, Ecto.UUID)
    timestamps()
  end

  def changeset(whiteboard, attrs) do
    whiteboard
    |> cast(attrs, [:tenant_id, :conversation_id, :sequence, :title])
    |> validate_required([:tenant_id, :conversation_id, :sequence])
    |> validate_number(:sequence, greater_than_or_equal_to: 0)
    |> unique_constraint([:tenant_id, :conversation_id],
      name: :whiteboards_tenant_conversation_unique
    )
  end
end
