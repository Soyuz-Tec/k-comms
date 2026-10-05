defmodule CommsCore.AudioCalls.Artifacts.Consent do
  @moduledoc false
  use CommsCore.Schema

  schema "call_artifact_consents" do
    field(:tenant_id, :binary_id)
    field(:artifact_id, :binary_id)
    field(:participant_id, :binary_id)
    field(:user_id, :binary_id)
    field(:session_id, :binary_id)
    field(:accepted, :boolean, default: false)
    field(:summary_accepted, :boolean, default: false)
    field(:summary_policy_version, :string)
    field(:summary_decided_at, :utc_datetime_usec)
    field(:policy_version, :string, default: "meeting-artifacts-v1")
    field(:decided_at, :utc_datetime_usec)
    timestamps()
  end

  def changeset(consent, attrs) do
    consent
    |> cast(attrs, [
      :tenant_id,
      :artifact_id,
      :participant_id,
      :user_id,
      :session_id,
      :accepted,
      :summary_accepted,
      :summary_policy_version,
      :summary_decided_at,
      :policy_version,
      :decided_at
    ])
    |> validate_required([
      :tenant_id,
      :artifact_id,
      :participant_id,
      :user_id,
      :session_id,
      :accepted,
      :policy_version
    ])
    |> unique_constraint([:artifact_id, :participant_id])
  end
end
