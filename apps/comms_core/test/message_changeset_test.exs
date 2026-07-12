defmodule CommsCore.MessageChangesetTest do
  use ExUnit.Case, async: true
  alias CommsCore.Messaging.Message
  test "requires tenant, sender, idempotency, and sequence fields" do
    changeset = Message.changeset(%Message{}, %{body: "hello"})
    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :tenant_id)
    assert Keyword.has_key?(changeset.errors, :conversation_sequence)
  end
end
