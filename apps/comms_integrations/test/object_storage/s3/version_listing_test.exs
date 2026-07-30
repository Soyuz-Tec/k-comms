defmodule CommsIntegrations.ObjectStorage.S3.VersionListingTest do
  use ExUnit.Case, async: true

  alias CommsIntegrations.ObjectStorage.S3.VersionListing

  @moduletag :unit
  @moduletag :object_storage

  test "parses exact versions, delete markers, pagination, and escaped keys" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListVersionsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Version>
        <Key>tenant/id/report &amp; notes.txt</Key>
        <VersionId>version-1</VersionId>
      </Version>
      <DeleteMarker>
        <Key>tenant/id/report &amp; notes.txt</Key>
        <VersionId>marker-1</VersionId>
      </DeleteMarker>
      <Version>
        <Key>tenant/id/legacy.txt</Key>
        <VersionId>null</VersionId>
      </Version>
      <IsTruncated>true</IsTruncated>
      <NextKeyMarker>tenant/id/report &amp; notes.txt</NextKeyMarker>
      <NextVersionIdMarker>version-1</NextVersionIdMarker>
    </ListVersionsResult>
    """

    assert {:ok, listing} = VersionListing.parse(xml)
    assert listing.truncated?
    assert listing.next_key_marker == "tenant/id/report & notes.txt"
    assert listing.next_version_id_marker == "version-1"

    assert listing.entries == [
             %{
               kind: :version,
               key: "tenant/id/report & notes.txt",
               version_id: "version-1"
             },
             %{
               kind: :delete_marker,
               key: "tenant/id/report & notes.txt",
               version_id: "marker-1"
             },
             %{kind: :version, key: "tenant/id/legacy.txt", version_id: "null"}
           ]
  end

  test "fails closed on malformed, entity-bearing, and oversized listings" do
    assert {:error, :object_version_listing_invalid} =
             VersionListing.parse("<ListVersionsResult><Version>")

    assert {:error, :object_version_listing_invalid} =
             VersionListing.parse("""
             <!DOCTYPE x [<!ENTITY expand "unsafe">]>
             <ListVersionsResult><Key>&expand;</Key></ListVersionsResult>
             """)

    assert {:error, :object_version_listing_too_large} =
             VersionListing.parse(String.duplicate("x", 262_145))
  end
end
