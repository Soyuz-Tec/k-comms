defmodule CommsCore.Conversations.Federation.Command do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @derive {Inspect, only: [:id, :tenant_id]}
  schema "federation_commands" do
    field(:tenant_id, :binary_id)
    field(:room_id, :binary_id)
    field(:user_id, :binary_id)
    field(:device_id, :binary_id)
    field(:session_id, :binary_id)
    field(:kind, :string)
    field(:request_key, :string)
    field(:payload_digest, :string)
    field(:target_receipt_id, :binary_id)
    field(:payload_box, :binary)
    field(:status, :string, default: "pending")
    field(:generation, :integer)
    field(:expected_room_version, :integer)
    field(:attempts, :integer, default: 0)
    field(:last_error, :string)
    field(:provider_receipt_box, :binary)
    field(:expires_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs),
    do:
      record
      |> cast(attrs, [
        :request_key,
        :payload_digest,
        :target_receipt_id,
        :tenant_id,
        :room_id,
        :user_id,
        :device_id,
        :session_id,
        :kind,
        :payload_box,
        :status,
        :generation,
        :expected_room_version,
        :attempts,
        :last_error,
        :provider_receipt_box,
        :expires_at
      ])
      |> validate_required([:tenant_id])
end
