defmodule CommsCore.AttachmentVariantsTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Attachments
  alias CommsCore.Attachments.{Attachment, AttachmentVariant}
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  @checksum String.duplicate("a", 64)
  @variant_checksum String.duplicate("b", 64)

  describe "declaring a thumbnail variant" do
    test "allocates a key inside the attachment's own prefix" do
      subject = subject()

      assert {:ok, attachment} = create_intent(subject)
      assert [variant] = attachment.variants

      assert variant.kind == :thumbnail
      assert variant.object_key == "#{attachment.tenant_id}/#{attachment.id}/thumbnail"
      assert variant.content_type == "image/webp"
      assert variant.byte_size == 4_096
      assert variant.checksum_sha256 == @variant_checksum

      # Intent is not proof: the version arrives only after verification.
      assert is_nil(variant.object_version_id)
      assert is_nil(variant.uploaded_at)
    end

    test "keeps the user-supplied file name out of the variant key" do
      subject = subject()

      assert {:ok, attachment} = create_intent(subject, %{file_name: "../../etc/passwd.png"})
      assert [variant] = attachment.variants

      refute variant.object_key =~ "passwd"
      assert String.ends_with?(variant.object_key, "/thumbnail")
    end

    test "creates no variant row when none is declared" do
      subject = subject()

      assert {:ok, attachment} = create_intent(subject, %{}, nil)
      assert attachment.variants == []
      assert Repo.aggregate(AttachmentVariant, :count) == 0
    end

    test "refuses a scriptable variant type" do
      subject = subject()

      # SVG renders script when served inline, which is exactly how a variant is
      # served. It must never be storable as one.
      assert {:error, :unsupported_thumbnail_content_type} =
               create_intent(subject, %{}, declared(%{content_type: "image/svg+xml"}))

      assert {:error, :unsupported_thumbnail_content_type} =
               create_intent(subject, %{}, declared(%{content_type: "text/html"}))
    end

    test "refuses a variant for content that is not an image" do
      subject = subject()

      assert {:error, :thumbnail_not_supported_for_content_type} =
               create_intent(subject, %{content_type: "application/pdf"})
    end

    test "refuses a variant larger than the bound" do
      subject = subject()

      assert {:error, :invalid_thumbnail_size} =
               create_intent(subject, %{}, declared(%{byte_size: 524_289}))

      assert {:error, :invalid_thumbnail_size} =
               create_intent(subject, %{}, declared(%{byte_size: 0}))
    end

    test "refuses a malformed variant checksum" do
      subject = subject()

      assert {:error, :invalid_thumbnail_checksum} =
               create_intent(subject, %{}, declared(%{checksum_sha256: "not-a-digest"}))
    end

    test "leaves no attachment behind when the variant cannot be inserted" do
      subject = subject()
      {:ok, first} = create_intent(subject)
      [variant] = first.variants

      # A second row reusing the same object key must fail, and it must take the
      # whole intent with it rather than stranding an attachment.
      before = Repo.aggregate(Attachment, :count)

      assert {:error, _} =
               %AttachmentVariant{}
               |> AttachmentVariant.changeset(%{
                 tenant_id: first.tenant_id,
                 attachment_id: first.id,
                 kind: :thumbnail,
                 object_key: variant.object_key,
                 content_type: "image/webp",
                 byte_size: 1_024,
                 checksum_sha256: @variant_checksum
               })
               |> Repo.insert()

      assert Repo.aggregate(Attachment, :count) == before
    end
  end

  describe "recording a verified variant" do
    test "stores the version and upload time together" do
      subject = subject()
      {:ok, attachment} = create_intent(subject)

      assert {:ok, recorded} =
               Attachments.record_variant(
                 attachment.id,
                 :thumbnail,
                 %{object_version_id: "variant-version-1"},
                 subject
               )

      assert [variant] = recorded.variants
      assert variant.object_version_id == "variant-version-1"
      assert %DateTime{} = variant.uploaded_at
    end

    test "refuses a kind the attachment never declared" do
      subject = subject()
      {:ok, attachment} = create_intent(subject, %{}, nil)

      assert {:error, :variant_not_declared} =
               Attachments.record_variant(
                 attachment.id,
                 :thumbnail,
                 %{object_version_id: "variant-version-1"},
                 subject
               )
    end

    test "refuses an absent version rather than recording an unreachable object" do
      subject = subject()
      {:ok, attachment} = create_intent(subject)

      for version <- [nil, "", "null"] do
        assert {:error, :variant_version_unavailable} =
                 Attachments.record_variant(
                   attachment.id,
                   :thumbnail,
                   %{object_version_id: version},
                   subject
                 )
      end
    end

    test "is owner-scoped" do
      account = Fixtures.account_fixture()
      subject = Fixtures.subject(account)
      foreign_user = Fixtures.user_fixture(account).user
      {:ok, attachment} = create_intent(subject)

      assert {:error, :not_found} =
               Attachments.record_variant(
                 attachment.id,
                 :thumbnail,
                 %{object_version_id: "variant-version-1"},
                 %{subject | user_id: foreign_user.id}
               )
    end
  end

  describe "serving a variant" do
    test "is withheld until the parent attachment is downloadable" do
      subject = subject()
      {:ok, attachment} = create_intent(subject)

      {:ok, recorded} =
        Attachments.record_variant(
          attachment.id,
          :thumbnail,
          %{object_version_id: "variant-version-1"},
          subject
        )

      # The variant is derived from content the scanner has not cleared, so it
      # must not become visible before the download it stands in for.
      refute Attachments.downloadable?(recorded)
      assert is_nil(Attachments.servable_variant(recorded, :thumbnail))
    end

    test "is withheld when no verified version exists" do
      subject = subject()
      {:ok, attachment} = create_intent(subject)

      assert is_nil(Attachments.servable_variant(attachment, :thumbnail))
    end
  end

  describe "erasure" do
    test "removes the variant rows outright" do
      subject = subject()
      {:ok, attachment} = create_intent(subject)

      {:ok, _} =
        Attachments.record_variant(
          attachment.id,
          :thumbnail,
          %{object_version_id: "variant-version-1"},
          subject
        )

      assert Repo.aggregate(AttachmentVariant, :count) == 1

      {:ok, {:ok, %{attachments_deleted: 1}}} =
        Repo.transaction(fn ->
          Attachments.mark_deleted_for_erasure(
            attachment.tenant_id,
            [attachment.id],
            DateTime.utc_now() |> DateTime.truncate(:microsecond)
          )
        end)

      assert Repo.aggregate(AttachmentVariant, :count) == 0
    end

    test "hands each variant identity to the deletion worker before clearing it" do
      subject = subject()
      {:ok, attachment} = create_intent(subject)

      {:ok, _} =
        Attachments.record_variant(
          attachment.id,
          :thumbnail,
          %{object_version_id: "variant-version-1"},
          subject
        )

      [object] = Attachments.erasure_objects(attachment.tenant_id, [], subject.user_id)

      assert [variant] = object.variants
      assert variant.object_key == "#{attachment.tenant_id}/#{attachment.id}/thumbnail"
      assert variant.object_version_id == "variant-version-1"
    end

    test "reports a declared-but-unverified variant so its key is still purged" do
      subject = subject()
      {:ok, attachment} = create_intent(subject)

      [object] = Attachments.erasure_objects(attachment.tenant_id, [], subject.user_id)

      assert [variant] = object.variants
      assert is_nil(variant.object_version_id)
    end
  end

  defp subject do
    account = Fixtures.account_fixture()
    Fixtures.subject(account)
  end

  defp create_intent(subject, overrides \\ %{}, thumbnail \\ :default) do
    thumbnail =
      case thumbnail do
        :default -> declared(%{})
        other -> other
      end

    attrs =
      Map.merge(
        %{
          file_name: "photo.png",
          content_type: "image/png",
          byte_size: 2_048,
          checksum_sha256: @checksum
        },
        overrides
      )

    attrs = if is_nil(thumbnail), do: attrs, else: Map.put(attrs, :thumbnail, thumbnail)

    Attachments.create_intent(attrs, subject)
  end

  defp declared(overrides) do
    Map.merge(
      %{
        content_type: "image/webp",
        byte_size: 4_096,
        checksum_sha256: @variant_checksum
      },
      overrides
    )
  end
end
