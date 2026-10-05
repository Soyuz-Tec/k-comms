defmodule CommsCore.Conversations.Federation.Participant do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @derive {Inspect, only: [:id, :tenant_id]}
  schema "federation_participants" do
    field(:tenant_id, :binary_id)
    field(:room_id, :binary_id)
    field(:user_id, :binary_id)
    field(:principal_hash, :string)
    field(:principal_box, :binary)
    field(:consent_status, :string, default: "invited")
    field(:lock_version, :integer, default: 1)
    field(:joined_observed_at, :utc_datetime_usec)
    field(:withdrawn_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs),
    do:
      record
      |> cast(attrs, [
        :tenant_id,
        :room_id,
        :user_id,
        :principal_hash,
        :principal_box,
        :consent_status,
        :lock_version,
        :joined_observed_at,
        :withdrawn_at
      ])
      |> validate_required([:tenant_id])
end
