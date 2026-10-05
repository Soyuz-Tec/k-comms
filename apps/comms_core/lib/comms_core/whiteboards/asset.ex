defmodule CommsCore.Whiteboards.Asset do
  @moduledoc false
  use CommsCore.Schema

  schema "whiteboard_assets" do
    field(:tenant_id, Ecto.UUID)
    field(:whiteboard_id, Ecto.UUID)
    field(:conversation_id, Ecto.UUID)
    field(:attachment_id, Ecto.UUID)
    field(:source_message_id, Ecto.UUID)
    field(:actor_user_id, Ecto.UUID)
    timestamps(updated_at: false)
  end
end
