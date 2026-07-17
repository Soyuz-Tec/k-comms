defmodule CommsCore.Attachments.RestoreRemap do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Attachments.Attachment
  alias CommsCore.Audit
  alias CommsCore.Repo

  @object_backed_statuses [:uploaded, :ready, :quarantined, :scan_failed]

  def run(verifier, context) when is_function(verifier, 1) and is_map(context) do
    with :ok <- validate_context(context),
         candidates <- candidates(),
         fail_closed_by_tenant <- unversioned_fail_closed_counts(),
         {:ok, verified} <- verify_all(candidates, verifier) do
      apply_verified(verified, context, fail_closed_by_tenant)
    end
  end

  def run(_verifier, _context), do: {:error, :invalid_restore_remap_invocation}

  defp candidates do
    Attachment
    |> where(
      [attachment],
      attachment.status != :deleted and not is_nil(attachment.object_version_id) and
        attachment.object_version_id != ""
    )
    |> order_by([attachment], asc: attachment.id)
    |> Repo.all()
  end

  defp unversioned_fail_closed_counts do
    Attachment
    |> where(
      [attachment],
      attachment.status in ^@object_backed_statuses and
        (is_nil(attachment.object_version_id) or attachment.object_version_id == "")
    )
    |> group_by([attachment], attachment.tenant_id)
    |> select([attachment], {attachment.tenant_id, count(attachment.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp verify_all(candidates, verifier) do
    Enum.reduce_while(candidates, {:ok, []}, fn attachment, {:ok, verified} ->
      case safely_verify(verifier, attachment) do
        {:ok, identity} ->
          case validate_identity(attachment, identity) do
            {:ok, identity} -> {:cont, {:ok, [{snapshot(attachment), identity} | verified]}}
            {:error, reason} -> {:halt, verification_error(attachment, reason)}
          end

        {:error, reason} ->
          {:halt, verification_error(attachment, reason)}
      end
    end)
    |> case do
      {:ok, verified} -> {:ok, Enum.reverse(verified)}
      {:error, _reason} = error -> error
    end
  end

  defp safely_verify(verifier, attachment) do
    verifier.(attachment)
  rescue
    _ -> {:error, :object_verification_failed}
  catch
    _, _ -> {:error, :object_verification_failed}
  end

  defp verification_error(attachment, reason) do
    {:error, {:verification_failed, attachment.id, safe_reason(reason)}}
  end

  defp validate_identity(attachment, identity) when is_map(identity) do
    version = value(identity, :object_version_id)
    etag = value(identity, :object_etag)
    checksum = normalize_checksum(value(identity, :verified_checksum_sha256))
    etag_verification = normalize_etag_verification(value(identity, :etag_verification))

    cond do
      not is_binary(version) or version in ["", "null"] ->
        {:error, :object_versioning_required}

      not is_binary(etag) or etag == "" ->
        {:error, :object_etag_unavailable}

      checksum != normalize_checksum(attachment.verified_checksum_sha256) or
          checksum != normalize_checksum(attachment.checksum_sha256) ->
        {:error, :object_checksum_mismatch}

      is_nil(etag_verification) ->
        {:error, :object_etag_verification_required}

      true ->
        {:ok,
         %{
           object_version_id: String.slice(version, 0, 1_024),
           object_etag: String.slice(etag, 0, 255),
           verified_checksum_sha256: checksum,
           etag_verification: etag_verification
         }}
    end
  end

  defp validate_identity(_attachment, _identity), do: {:error, :object_verification_failed}

  defp apply_verified(verified, context, fail_closed_by_tenant) do
    Repo.transaction(fn ->
      locked = lock_candidates(verified)

      unless candidates_unchanged?(locked, verified) do
        Repo.rollback(:restore_candidates_changed)
      end

      results =
        Enum.map(verified, fn {candidate, identity} ->
          attachment = Map.fetch!(locked, candidate.id)
          changed? = attachment.object_version_id != identity.object_version_id

          if changed? do
            attachment
            |> Attachment.changeset(%{
              object_version_id: identity.object_version_id,
              object_etag: identity.object_etag
            })
            |> Repo.update!()

            audit_attachment!(attachment, identity, context)
          end

          %{tenant_id: attachment.tenant_id, changed?: changed?, identity: identity}
        end)

      audit_summaries!(results, context, fail_closed_by_tenant)
      report(results, fail_closed_by_tenant)
    end)
    |> case do
      {:ok, report} -> {:ok, report}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_candidates(verified) do
    ids = Enum.map(verified, fn {candidate, _identity} -> candidate.id end)

    Attachment
    |> where([attachment], attachment.id in ^ids)
    |> order_by([attachment], asc: attachment.id)
    |> lock("FOR UPDATE")
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp candidates_unchanged?(locked, verified) do
    map_size(locked) == length(verified) and
      Enum.all?(verified, fn {candidate, _identity} ->
        case Map.get(locked, candidate.id) do
          %Attachment{} = attachment -> snapshot(attachment) == candidate
          nil -> false
        end
      end)
  end

  defp snapshot(attachment) do
    Map.take(attachment, [
      :id,
      :tenant_id,
      :status,
      :object_key,
      :byte_size,
      :checksum_sha256,
      :object_version_id,
      :object_etag,
      :verified_checksum_sha256,
      :updated_at
    ])
  end

  defp audit_attachment!(attachment, identity, context) do
    Audit.record(%{
      tenant_id: attachment.tenant_id,
      action: "attachment.restore_version_remapped",
      resource_type: "attachment",
      resource_id: attachment.id,
      metadata: %{
        actor: value(context, :actor),
        reason: value(context, :reason),
        restore_operation_id: value(context, :operation_id),
        previous_version_fingerprint: fingerprint(attachment.object_version_id),
        restored_version_fingerprint: fingerprint(identity.object_version_id),
        etag_verification: Atom.to_string(identity.etag_verification)
      },
      request_id: "restore:#{value(context, :operation_id)}"
    })
    |> audit_or_rollback()
  end

  defp audit_summaries!(results, context, fail_closed_by_tenant) do
    results_by_tenant = Enum.group_by(results, & &1.tenant_id)

    tenant_ids(results, fail_closed_by_tenant)
    |> Enum.each(fn tenant_id ->
      tenant_results = Map.get(results_by_tenant, tenant_id, [])

      tenant_report =
        report(tenant_results, %{tenant_id => Map.get(fail_closed_by_tenant, tenant_id, 0)})

      Audit.record(%{
        tenant_id: tenant_id,
        action: "attachment.restore_version_remap_completed",
        resource_type: "attachment_restore",
        resource_id: tenant_id,
        metadata:
          Map.merge(tenant_report, %{
            actor: value(context, :actor),
            reason: value(context, :reason),
            restore_operation_id: value(context, :operation_id)
          }),
        request_id: "restore:#{value(context, :operation_id)}"
      })
      |> audit_or_rollback()
    end)
  end

  defp audit_or_rollback({:ok, event}), do: event
  defp audit_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp report(results, fail_closed_by_tenant) do
    %{
      candidate_count: length(results),
      verified_count: length(results),
      remapped_count: Enum.count(results, & &1.changed?),
      unchanged_count: Enum.count(results, &(not &1.changed?)),
      trustworthy_etag_count: Enum.count(results, &(&1.identity.etag_verification == :matched)),
      untrusted_etag_count:
        Enum.count(results, &(&1.identity.etag_verification == :not_trustworthy)),
      unversioned_fail_closed_count: fail_closed_by_tenant |> Map.values() |> Enum.sum(),
      tenant_count: results |> tenant_ids(fail_closed_by_tenant) |> length()
    }
  end

  defp tenant_ids(results, fail_closed_by_tenant) do
    results
    |> Enum.map(& &1.tenant_id)
    |> Kernel.++(Map.keys(fail_closed_by_tenant))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp validate_context(context) do
    operation_id = value(context, :operation_id)
    actor = value(context, :actor)
    reason = value(context, :reason)

    if valid_uuid?(operation_id) and safe_text?(actor, 255) and safe_text?(reason, 500),
      do: :ok,
      else: {:error, :invalid_restore_audit_context}
  end

  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp valid_uuid?(_value), do: false

  defp safe_text?(value, max) when is_binary(value) do
    value = String.trim(value)
    value != "" and byte_size(value) <= max
  end

  defp safe_text?(_value, _max), do: false

  defp normalize_checksum(checksum) when is_binary(checksum),
    do: checksum |> String.trim() |> String.downcase()

  defp normalize_checksum(_checksum), do: nil

  defp normalize_etag_verification(value) when value in [:matched, "matched"], do: :matched

  defp normalize_etag_verification(value)
       when value in [:not_trustworthy, "not_trustworthy"],
       do: :not_trustworthy

  defp normalize_etag_verification(_value), do: nil

  defp fingerprint(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp safe_reason(reason) when is_atom(reason), do: reason

  defp safe_reason({:object_storage_status, status}) when is_integer(status),
    do: {:object_storage_status, status}

  defp safe_reason({:missing_s3_config, key}) when is_atom(key),
    do: {:missing_s3_config, key}

  defp safe_reason(_reason), do: :object_verification_failed
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
