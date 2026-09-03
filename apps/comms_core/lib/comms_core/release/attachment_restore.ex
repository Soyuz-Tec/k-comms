defmodule CommsCore.Release.AttachmentRestore do
  @moduledoc false

  alias CommsCore.{Attachments, Release.Environment, Repo}
  alias CommsCore.Attachments.{RestoreCandidate, RestoredObjectIdentity}

  @app :comms_core

  @spec remap_restored_attachment_versions((RestoreCandidate.t() ->
                                              {:ok, RestoredObjectIdentity.t()}
                                              | {:error,
                                                 CommsCore.Attachments.restore_verification_error()})) ::
          :ok
  def remap_restored_attachment_versions(verifier) when is_function(verifier, 1) do
    with {:ok, context} <- Environment.validate_restore_remap(&System.get_env/1) do
      load_app()

      {:ok, result, _started_apps} =
        Ecto.Migrator.with_repo(Repo, fn _repo ->
          Attachments.remap_restored_attachment_versions(verifier, context)
        end)

      case result do
        {:ok, report} ->
          IO.puts(
            "Attachment restore remap completed: " <>
              "candidates=#{report.candidate_count} " <>
              "verified=#{report.verified_count} " <>
              "remapped=#{report.remapped_count} " <>
              "unchanged=#{report.unchanged_count} " <>
              "etag_matched=#{report.trustworthy_etag_count} " <>
              "etag_untrusted=#{report.untrusted_etag_count} " <>
              "unversioned_fail_closed=#{report.unversioned_fail_closed_count} " <>
              "tenants=#{report.tenant_count}"
          )

          :ok

        {:error, {:verification_failed, attachment_id, reason}} ->
          raise "attachment restore remap aborted before database update: " <>
                  "attachment=#{attachment_id} reason=#{restore_error(reason)}"

        {:error, reason} ->
          raise "attachment restore remap failed: #{restore_error(reason)}"
      end
    else
      {:error, reason} -> raise "attachment restore remap refused: #{restore_error(reason)}"
    end
  end

  defp load_app do
    Application.load(@app)
  end

  defp restore_error(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp restore_error({:object_storage_status, status}) when is_integer(status),
    do: "object_storage_status_#{status}"

  defp restore_error({:missing_s3_config, key}) when is_atom(key),
    do: "missing_s3_config_#{key}"

  defp restore_error(_reason), do: "restore_operation_failed"
end
