defmodule CommsCore.Messaging.PersonalContent.SavedItem do
  @moduledoc false
  use CommsCore.Schema

  schema "message_saved_items" do
    field(:tenant_id, Ecto.UUID)
    field(:user_id, Ecto.UUID)
    field(:message_id, Ecto.UUID)
    timestamps(updated_at: false)
  end
end
