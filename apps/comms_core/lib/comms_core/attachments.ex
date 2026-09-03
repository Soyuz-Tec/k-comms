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

  @type restore_verification_error ::
          atom()
          | {:missing_s3_config, atom()}
          | {:object_storage_status, non_neg_integer()}

  @typedoc "Scalar values allowed across this facade boundary."
  @type public_scalar ::
          atom()
          | binary()
          | boolean()
          | integer()
          | float()
          | DateTime.t()
          | NaiveDateTime.t()
          | nil

  @typedoc "Persistence-neutral structured data with scalar leaves."
  @type public_map :: %{
          optional(atom() | binary()) =>
            public_scalar() | public_map() | [public_scalar() | public_map()]
        }

  @typedoc "Named DTOs owned by this bounded context."
  @type public_contract ::
          CommsCore.Attachments.AttachmentDeletionObject.t()
          | CommsCore.Attachments.AttachmentView.t()
          | CommsCore.Attachments.FileView.t()
          | CommsCore.Attachments.RestoreCandidate.t()
          | CommsCore.Attachments.RestoreContext.t()
          | CommsCore.Attachments.RestoreReport.t()
          | CommsCore.Attachments.RestoredObjectIdentity.t()
          | CommsCore.Attachments.ScanAttemptView.t()

  @type public_value :: public_scalar() | public_map() | public_contract()
  @type public_input ::
          public_value() | [public_value()] | function() | module()
  @type public_error ::
          atom()
          | CommsCore.ValidationError.t()
          | public_map()
          | {atom(), public_scalar() | public_map()}
  @type public_response ::
          public_value()
          | [public_value()]
          | {:ok, public_value() | [public_value()]}
          | {:error, public_error()}

  @spec abandon_intent(binary(), public_map()) :: public_response()
  @spec claim_abandon_cleanup(binary(), binary(), module()) :: public_response()
  @spec claim_scan(binary()) :: public_response()
  @spec complete_abandon_cleanup(binary(), binary(), module()) :: public_response()
  @spec create_intent(public_map(), public_map()) :: public_response()
  @spec downloadable?(public_map()) :: boolean()
  @spec get_authorized(binary(), public_map()) :: public_response()
  @spec list_files(public_map(), public_map()) ::
          [public_value()] | {:ok, [public_value()]} | {:error, public_error()}
  @spec list_safety(public_map(), keyword() | public_map()) ::
          [public_value()] | {:ok, [public_value()]} | {:error, public_error()}
  @spec mark_uploaded(binary(), binary(), public_map(), public_map()) :: public_response()
  @spec reconcile_abandon_cleanups(module()) :: public_response()
  @spec record_abandon_cleanup_failure(binary(), binary(), atom() | binary(), boolean(), module()) ::
          public_response()
  @spec record_scan(public_map(), public_map()) :: public_response()
  @spec record_upload_authorization(binary(), DateTime.t() | NaiveDateTime.t(), public_map()) ::
          public_response()
  @spec record_variant(binary(), atom() | binary(), public_map(), public_map()) ::
          public_response()
  @spec retry_scan(binary(), public_map()) :: public_response()
  @spec servable_variant(public_map(), atom() | binary()) :: public_response()

  @spec remap_restored_attachment_versions(
          (RestoreCandidate.t() ->
             {:ok, RestoredObjectIdentity.t()} | {:error, restore_verification_error()}),
          RestoreContext.t()
        ) :: {:ok, RestoreReport.t()} | {:error, public_error()}
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
