defmodule CommsCore.Telephony.ProviderEvent do
  @moduledoc false
  use CommsCore.Schema

  schema "telephony_provider_events" do
    field(:tenant_id, :binary_id)
    field(:call_id, :binary_id)
    field(:event_id, :string)
    field(:event_type, :string)
    field(:participant_sid, :string)
    field(:occurred_at, :utc_datetime_usec)
    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:tenant_id, :call_id, :event_id, :event_type, :participant_sid, :occurred_at])
    |> validate_required([:tenant_id, :call_id, :event_id, :event_type])
    |> validate_length(:event_id, max: 200)
    |> validate_length(:participant_sid, max: 200)
    |> unique_constraint(:event_id)
  end
end
