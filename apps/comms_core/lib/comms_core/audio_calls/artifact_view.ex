defmodule CommsCore.AudioCalls.ArtifactView do
  @moduledoc "Authorized meeting artifact metadata; storage identities and consent sessions remain private."
  @enforce_keys [:id, :conversation_id, :call_id, :kind, :status, :created_at]
  defstruct [
    :id,
    :conversation_id,
    :call_id,
    :meeting_id,
    :source_artifact_id,
    :transcript_language,
    :summary_requested,
    :summary_policy_version,
    :summary_consent_required_count,
    :summary_consent_accepted_count,
    :my_summary_consent,
    :can_withdraw_summary_consent,
    :summary_request_available,
    :recognition_mode,
    :recognition_model_sha256,
    :kind,
    :status,
    :created_at,
    :started_at,
    :ended_at,
    :expires_at,
    :failure_code,
    :consent_required_count,
    :consent_accepted_count,
    :my_consent,
    :can_manage,
    :byte_size,
    :content_type
  ]

  @type t :: %__MODULE__{}
end
