defmodule CommsCore.Governance.BoundaryTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :governance

  test "governance facade contains no foreign persistence-schema reach-through" do
    source =
      __DIR__
      |> Path.join("../../lib/comms_core/governance.ex")
      |> Path.expand()
      |> File.read!()

    refute source =~ "CommsCore.Accounts.User"
    refute source =~ "CommsCore.Attachments.Attachment"
    refute source =~ "CommsCore.Conversations.Conversation"
    refute source =~ "CommsCore.Messaging.Message"
  end
end
