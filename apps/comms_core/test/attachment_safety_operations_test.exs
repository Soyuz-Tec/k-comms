defmodule CommsCore.AttachmentSafetyOperationsTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Attachments
  alias CommsCore.Attachments.{Attachment, AttachmentView, ScanAttempt}
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :attachment

  test "attachments remain unavailable until a clean scanner verdict and block malicious files" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, pending} =
             create_intent(subject, "evidence.txt", 12, String.duplicate("a", 64))

    assert %AttachmentView{} = pending
    refute match?(%Attachment{}, pending)

    assert {:ok, uploaded} =
             Attachments.mark_uploaded(
               pending.id,
               String.duplicate("a", 64),
               identity(String.duplicate("a", 64), "clean"),
               subject
             )

    assert uploaded.status == :uploaded
    assert uploaded.scan_status == :pending
    refute uploaded.status == :ready
    assert {:ok, scanning} = Attachments.claim_scan(uploaded.id)

    assert {:ok, ready} =
             Attachments.record_scan(
               scanning,
               {:ok, %{verdict: :clean, provider: "test", provider_reference: "scan-1"}}
             )

    assert ready.status == :ready
    assert ready.scan_status == :clean
    assert ready.scan_attempts == 1
    assert Repo.aggregate(ScanAttempt, :count) == 1

    checksum = String.duplicate("b", 64)
    assert {:ok, malicious_pending} = create_intent(subject, "bad.txt", 8, checksum)

    assert {:ok, malicious_uploaded} =
             Attachments.mark_uploaded(
               malicious_pending.id,
               checksum,
               identity(checksum, "blocked"),
               subject
             )

    assert {:ok, malicious_scanning} = Attachments.claim_scan(malicious_uploaded.id)

    assert {:ok, quarantined} =
             Attachments.record_scan(
               malicious_scanning,
               {:ok, %{verdict: :malicious, provider: "test"}}
             )

    assert quarantined.status == :quarantined
    assert quarantined.scan_status == :blocked
    assert quarantined.quarantined_at
  end

  test "attachment safety administration uses verified identity grants and requires step-up for retry" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, pending} =
             create_intent(subject, "retry.txt", 12, String.duplicate("f", 64))

    assert {:ok, listed} = Attachments.list_safety(subject, %{scan_status: :pending})
    assert Enum.any?(listed, &(&1.id == pending.id))
    assert {:error, :step_up_required} = Attachments.retry_scan(pending.id, subject)

    stepped_up_subject = Fixtures.step_up(account, subject)
    assert {:ok, retried} = Attachments.retry_scan(pending.id, stepped_up_subject)
    assert retried.id == pending.id
    assert retried.scan_status == :pending
  end

  @tag :concurrency
  test "a stale clean scanner result cannot reverse a newer blocked verdict" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    checksum = String.duplicate("c", 64)

    {:ok, pending} = create_intent(subject, "race.txt", 16, checksum)

    {:ok, uploaded} =
      Attachments.mark_uploaded(pending.id, checksum, identity(checksum, "race"), subject)

    {:ok, first_claim} = Attachments.claim_scan(uploaded.id)

    first_claim.id
    |> then(&Repo.get!(Attachment, &1))
    |> Attachment.changeset(%{
      status: :scan_failed,
      scan_status: :failed,
      scan_claim_token: nil,
      scan_claimed_at: nil
    })
    |> Repo.update!()

    {:ok, second_claim} = Attachments.claim_scan(uploaded.id)

    assert {:ok, blocked} =
             Attachments.record_scan(
               second_claim,
               {:ok, %{verdict: :malicious, provider: "test"}}
             )

    assert blocked.status == :quarantined

    assert {:error, :stale_scan_claim} =
             Attachments.record_scan(first_claim, {:ok, %{verdict: :clean, provider: "test"}})

    persisted = Repo.get!(Attachment, uploaded.id)
    assert persisted.status == :quarantined
    assert persisted.scan_status == :blocked
  end

  test "tenant attachment size policy is enforced before an upload intent is issued" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    %CommsCore.Administration.TenantSettings{}
    |> CommsCore.Administration.TenantSettings.changeset(%{
      tenant_id: account.tenant.id,
      max_attachment_bytes: 10
    })
    |> Repo.insert!()

    assert {:error, :invalid_attachment_size} =
             create_intent(subject, "too-large.txt", 11, String.duplicate("d", 64))

    assert {:ok, _attachment} =
             create_intent(subject, "allowed.txt", 10, String.duplicate("e", 64))
  end

  defp create_intent(subject, file_name, byte_size, checksum) do
    Attachments.create_intent(
      %{
        file_name: file_name,
        content_type: "text/plain",
        byte_size: byte_size,
        checksum_sha256: checksum
      },
      subject
    )
  end

  defp identity(checksum, suffix) do
    %{
      object_version_id: "version-#{suffix}",
      object_etag: "\"etag-#{suffix}\"",
      verified_checksum_sha256: checksum
    }
  end
end
