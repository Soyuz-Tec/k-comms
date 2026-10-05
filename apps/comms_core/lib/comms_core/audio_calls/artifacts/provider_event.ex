defmodule CommsCore.AudioCalls.Artifacts.ProviderEvent do
  @moduledoc false
  use CommsCore.Schema

  schema "call_artifact_provider_events" do
    field(:tenant_id, :binary_id)
    field(:artifact_id, :binary_id)
    field(:event_id, :string)
    field(:body_sha256, :string)
    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:tenant_id, :artifact_id, :event_id, :body_sha256])
    |> validate_required([:tenant_id, :artifact_id, :event_id, :body_sha256])
    |> unique_constraint(:event_id)
  end
end
