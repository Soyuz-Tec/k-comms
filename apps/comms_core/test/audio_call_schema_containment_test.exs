defmodule CommsCore.AudioCalls.SchemaContainmentTest do
  use ExUnit.Case, async: true

  alias CommsCore.AudioCalls.{AudioCall, AudioCallParticipant}

  test "foreign tenant, conversation, and identity references remain scalar binary IDs" do
    assert_binary_id_fields(AudioCall, [
      :tenant_id,
      :conversation_id,
      :started_by_user_id,
      :ended_by_user_id
    ])

    assert_binary_id_fields(AudioCallParticipant, [
      :tenant_id,
      :conversation_id,
      :user_id,
      :device_id,
      :session_id
    ])
  end

  test "foreign associations are absent and the Calls-owned association remains intact" do
    for association <- [:tenant, :conversation, :started_by_user, :ended_by_user] do
      refute association in AudioCall.__schema__(:associations)
    end

    for association <- [:tenant, :conversation, :user, :device, :session] do
      refute association in AudioCallParticipant.__schema__(:associations)
    end

    assert :audio_call in AudioCallParticipant.__schema__(:associations)

    assert AudioCallParticipant.__schema__(:association, :audio_call).related ==
             AudioCall
  end

  defp assert_binary_id_fields(schema, fields) do
    for field <- fields do
      assert schema.__schema__(:type, field) == :binary_id
    end
  end
end
