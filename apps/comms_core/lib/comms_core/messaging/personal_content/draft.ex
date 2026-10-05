defmodule CommsCore.Messaging.PersonalContent.Draft do
  @moduledoc false
  use CommsCore.Schema

  schema "message_drafts" do
    field(:tenant_id, Ecto.UUID)
    field(:user_id, Ecto.UUID)
    field(:conversation_id, Ecto.UUID)
    field(:thread_key, :string)
    field(:body, :string, default: "")
    field(:version, :integer)
    field(:expires_at, :utc_datetime_usec)
    timestamps()
  end
end
