defmodule CommsCore.AudioCalls.Artifacts.Segment do
  @moduledoc false
  use CommsCore.Schema

  schema "call_artifact_segments" do
    field(:tenant_id, :binary_id)
    field(:artifact_id, :binary_id)
    field(:sequence, :integer)
    field(:start_ms, :integer)
    field(:end_ms, :integer)
    field(:text, :string)
    timestamps(updated_at: false)
  end

  def changeset(segment, attrs) do
    segment
    |> cast(attrs, [:tenant_id, :artifact_id, :sequence, :start_ms, :end_ms, :text])
    |> validate_required([:tenant_id, :artifact_id, :sequence, :start_ms, :end_ms, :text])
    |> validate_number(:sequence, greater_than_or_equal_to: 0, less_than: 10_000)
    |> validate_number(:start_ms, greater_than_or_equal_to: 0, less_than_or_equal_to: 28_800_000)
    |> validate_number(:end_ms, greater_than_or_equal_to: 0, less_than_or_equal_to: 28_800_000)
    |> validate_length(:text, min: 1, max: 8_000)
    |> unique_constraint([:artifact_id, :sequence])
  end
end
