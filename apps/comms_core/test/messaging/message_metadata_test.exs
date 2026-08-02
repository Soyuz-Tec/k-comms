defmodule CommsCore.Messaging.MessageMetadataTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :messaging

  alias CommsCore.Messaging.MessageMetadata

  test "accepts bounded whiteboard references and HTTPS link cards" do
    metadata = %{
      "whiteboard_reference" => %{
        "element_ids" => ["element-0001", "element-0002"],
        "board_sequence" => 42,
        "label" => "Architecture sketch",
        "region" => %{"x" => -10.5, "y" => 20, "width" => 640, "height" => 480}
      },
      "links" => [
        %{"url" => "https://docs.example.test/guide", "label" => "Guide"}
      ]
    }

    assert :ok = MessageMetadata.validate(metadata)
  end

  test "rejects unsafe links and malformed whiteboard coordinates" do
    assert {:error, :invalid_message_link} =
             MessageMetadata.validate(%{"links" => [%{"url" => "http://example.test"}]})

    assert {:error, :invalid_message_link} =
             MessageMetadata.validate(%{
               "links" => [%{"url" => "https://user:secret@example.test/private"}]
             })

    assert {:error, :invalid_whiteboard_reference} =
             MessageMetadata.validate(%{
               "whiteboard_reference" => %{
                 "element_ids" => [],
                 "region" => %{"x" => 0, "y" => 0, "width" => -1, "height" => 20}
               }
             })
  end

  test "enforces collection limits and unique element identifiers" do
    links = Enum.map(1..6, &%{"url" => "https://example.test/#{&1}"})
    assert {:error, :too_many_message_links} = MessageMetadata.validate(%{"links" => links})

    assert {:error, :invalid_whiteboard_reference} =
             MessageMetadata.validate(%{
               "whiteboard_reference" => %{
                 "element_ids" => ["duplicate-element", "duplicate-element"]
               }
             })
  end
end
