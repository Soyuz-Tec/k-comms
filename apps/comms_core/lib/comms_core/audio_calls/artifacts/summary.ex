defmodule CommsCore.AudioCalls.Artifacts.Summary do
  @moduledoc false
  use CommsCore.Schema

  schema "call_artifact_summaries" do
    field(:tenant_id, :binary_id)
    field(:artifact_id, :binary_id)
    field(:source_artifact_id, :binary_id)
    field(:source_sha256, :string)
    field(:summary_sha256, :string)
    field(:policy_version, :string)
    field(:provider_id, :string)
    field(:provider_model, :string)
    field(:text, :string)
    timestamps(updated_at: false)
  end

  def changeset(summary, attrs) do
    summary
    |> cast(attrs, __schema__(:fields) -- [:inserted_at])
    |> validate_required([
      :tenant_id,
      :artifact_id,
      :source_artifact_id,
      :source_sha256,
      :summary_sha256,
      :policy_version,
      :provider_id,
      :provider_model,
      :text
    ])
    |> validate_format(:source_sha256, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:summary_sha256, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:text, min: 1, max: 16_384)
    |> unique_constraint(:artifact_id)
  end
end
