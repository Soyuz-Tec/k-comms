defmodule CommsCore.Attachments do
  @moduledoc """
  Public ConversationContent facade for attachment operations.

  Persistence and lifecycle details remain in owner-internal modules so web,
  worker, and cross-context callers retain one stable API.
  """

  alias CommsCore.Attachments.{
    Abandonment,
    Erasure,
    FileQueries,
    MessageClaims,
    RestoreCandidate,
    RestoreContext,
    RestoreRemap,
    RestoreReport,
    RestoredObjectIdentity,
    Safety,
    Uploads
  }

  @spec remap_restored_attachment_versions(
          (RestoreCandidate.t() -> {:ok, RestoredObjectIdentity.t()} | {:error, term()}),
          RestoreContext.t()
        ) :: {:ok, RestoreReport.t()} | {:error, term()}
  def remap_restored_attachment_versions(verifier, %RestoreContext{} = context)
      when is_function(verifier, 1),
      do: RestoreRemap.run(verifier, context)

  def remap_restored_attachment_versions(_verifier, _context),
    do: {:error, :invalid_restore_remap_invocation}

  defdelegate erasure_objects(tenant_id, message_ids, owner_user_id), to: Erasure
  defdelegate mark_deleted_for_erasure(tenant_id, attachment_ids, timestamp), to: Erasure

  defdelegate create_intent(attrs, subject), to: Uploads
  defdelegate record_variant(id, kind, identity, subject), to: Uploads
  defdelegate servable_variant(attachment, kind), to: Uploads
  defdelegate record_upload_authorization(id, expires_at, subject), to: Uploads
  defdelegate mark_uploaded(id, checksum, identity, subject), to: Uploads
  defdelegate get_authorized(id, subject), to: Uploads

  defdelegate abandon_intent(id, subject), to: Abandonment
  defdelegate claim_abandon_cleanup(tenant_id, id, caller), to: Abandonment
  defdelegate complete_abandon_cleanup(tenant_id, id, caller), to: Abandonment

  defdelegate record_abandon_cleanup_failure(tenant_id, id, reason, terminal?, caller),
    to: Abandonment

  defdelegate reconcile_abandon_cleanups(caller), to: Abandonment

  defdelegate list_files(subject, params \\ %{}), to: FileQueries
  defdelegate list_for_message(message_id), to: FileQueries

  defdelegate list_safety(subject, opts \\ %{}), to: Safety
  defdelegate claim_scan(id), to: Safety
  defdelegate record_scan(attachment, result), to: Safety
  defdelegate retry_scan(id, subject), to: Safety
  defdelegate downloadable?(attachment), to: Safety

  defdelegate attach_ready(ids, message_id, tenant_id, subject), to: MessageClaims
end
