defmodule CommsWorkers.Release do
  @moduledoc false

  alias CommsCore.Attachments.{RestoreCandidate, RestoredObjectIdentity}
  alias CommsCore.Release, as: CoreRelease
  alias CommsIntegrations.ObjectStorage

  def remap_restored_attachment_versions do
    {:ok, _started} = Application.ensure_all_started(:comms_integrations)

    CoreRelease.remap_restored_attachment_versions(&verify_restored_object/1)
  end

  defp verify_restored_object(%RestoreCandidate{} = candidate) do
    with {:ok, identity} <- ObjectStorage.verify_restored_object(candidate) do
      {:ok,
       %RestoredObjectIdentity{
         object_version_id: identity.object_version_id,
         object_etag: identity.object_etag,
         verified_checksum_sha256: identity.verified_checksum_sha256,
         etag_verification: identity.etag_verification
       }}
    end
  end
end
