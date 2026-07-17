defmodule CommsCore.AttachmentRestoreRemapTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Attachments
  alias CommsCore.Attachments.Attachment
  alias CommsCore.Attachments.RestoreRemap
  alias CommsCore.Audit
  alias CommsCore.Release
  alias CommsTestSupport.Fixtures

  test "verified restored versions are remapped in one transaction with redacted audits" do
    account = Fixtures.account_fixture()
    first = uploaded_attachment(account, "first.txt", "first restored body")
    second = uploaded_attachment(account, "second.txt", "second restored body")
    context = restore_context()

    verifier = fn attachment ->
      version =
        if attachment.id == first.id, do: "restored-first", else: attachment.object_version_id

      {:ok,
       %{
         object_version_id: version,
         object_etag: attachment.object_etag,
         verified_checksum_sha256: attachment.verified_checksum_sha256,
         etag_verification: :matched
       }}
    end

    assert {:ok,
            %{
              candidate_count: 2,
              verified_count: 2,
              remapped_count: 1,
              unchanged_count: 1,
              trustworthy_etag_count: 2,
              untrusted_etag_count: 0,
              tenant_count: 1
            }} = RestoreRemap.run(verifier, context)

    assert Repo.get!(Attachment, first.id).object_version_id == "restored-first"
    assert Repo.get!(Attachment, second.id).object_version_id == second.object_version_id

    remap_audit =
      Audit.get_by!(%{
        tenant_id: account.tenant.id,
        action: "attachment.restore_version_remapped"
      })

    assert remap_audit.resource_id == first.id
    assert remap_audit.metadata["actor"] == context.actor
    assert remap_audit.metadata["reason"] == context.reason
    assert remap_audit.metadata["restore_operation_id"] == context.operation_id
    assert remap_audit.metadata["etag_verification"] == "matched"
    refute inspect(remap_audit.metadata) =~ first.object_version_id
    refute inspect(remap_audit.metadata) =~ "restored-first"

    summary =
      Audit.get_by!(%{
        tenant_id: account.tenant.id,
        action: "attachment.restore_version_remap_completed"
      })

    assert summary.resource_id == account.tenant.id
    assert summary.metadata["candidate_count"] == 2
    assert summary.metadata["remapped_count"] == 1
    assert summary.metadata["unchanged_count"] == 1
  end

  test "a missing or mismatched restored object aborts before any database update" do
    account = Fixtures.account_fixture()
    first = uploaded_attachment(account, "first.txt", "first restored body")
    second = uploaded_attachment(account, "mismatch.txt", "mismatched body")
    audit_count = Audit.count(%{tenant_id: account.tenant.id})

    verifier = fn attachment ->
      if attachment.id == second.id do
        {:error, :object_checksum_mismatch}
      else
        {:ok,
         %{
           object_version_id: "must-not-commit",
           object_etag: attachment.object_etag,
           verified_checksum_sha256: attachment.verified_checksum_sha256,
           etag_verification: :matched
         }}
      end
    end

    assert {:error, {:verification_failed, failed_id, :object_checksum_mismatch}} =
             RestoreRemap.run(verifier, restore_context())

    assert failed_id == second.id
    assert Repo.get!(Attachment, first.id).object_version_id == first.object_version_id
    assert Repo.get!(Attachment, second.id).object_version_id == second.object_version_id
    assert Audit.count(%{tenant_id: account.tenant.id}) == audit_count
  end

  test "release guard requires a confirmed one-shot operation and complete audit context" do
    operation_id = Ecto.UUID.generate()

    environment = %{
      "K_COMMS_RUNTIME_PURPOSE" => "one_shot",
      "K_COMMS_RESTORE_VERSION_REMAP" => "remap-restored-attachment-versions",
      "K_COMMS_RESTORE_OPERATION_ID" => operation_id,
      "K_COMMS_RESTORE_ACTOR" => "staging-release@example.test",
      "K_COMMS_RESTORE_REASON" => "Validate portable object-store disaster recovery"
    }

    assert {:ok, context} =
             Release.validate_restore_remap_environment(&Map.get(environment, &1))

    assert context.operation_id == operation_id

    assert {:error, :one_shot_runtime_required} =
             Release.validate_restore_remap_environment(
               &(environment
                 |> Map.put("K_COMMS_RUNTIME_PURPOSE", "application")
                 |> Map.get(&1))
             )

    assert {:error, :restore_remap_confirmation_required} =
             Release.validate_restore_remap_environment(
               &(environment
                 |> Map.delete("K_COMMS_RESTORE_VERSION_REMAP")
                 |> Map.get(&1))
             )

    assert {:error, :restore_operation_id_required} =
             Release.validate_restore_remap_environment(
               &(environment
                 |> Map.put("K_COMMS_RESTORE_OPERATION_ID", "not-a-uuid")
                 |> Map.get(&1))
             )

    assert {:error, :restore_actor_required} =
             Release.validate_restore_remap_environment(
               &(environment
                 |> Map.put("K_COMMS_RESTORE_ACTOR", " ")
                 |> Map.get(&1))
             )
  end

  defp uploaded_attachment(account, file_name, body) do
    checksum = sha256(body)
    subject = Fixtures.subject(account)

    {:ok, pending} =
      Attachments.create_intent(
        %{
          file_name: file_name,
          content_type: "text/plain",
          byte_size: byte_size(body),
          checksum_sha256: checksum
        },
        subject
      )

    {:ok, uploaded} =
      Attachments.mark_uploaded(
        pending.id,
        checksum,
        %{
          object_version_id: "original-#{pending.id}",
          object_etag: "\"#{md5(body)}\"",
          verified_checksum_sha256: checksum
        },
        subject
      )

    uploaded
  end

  defp restore_context do
    %{
      operation_id: Ecto.UUID.generate(),
      actor: "staging-release@example.test",
      reason: "Restore rehearsal"
    }
  end

  defp sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
  defp md5(body), do: :crypto.hash(:md5, body) |> Base.encode16(case: :lower)
end
