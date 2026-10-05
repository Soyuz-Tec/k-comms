defmodule CommsCore.Conversations.Federation.Trust do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @derive {Inspect, only: [:id, :tenant_id]}
  schema "federation_trusts" do
    field(:tenant_id, :binary_id)
    field(:domain, :string)
    field(:residency, :string)
    field(:cross_border_reason, :string)
    field(:enabled, :boolean, default: false)
    field(:lock_version, :integer, default: 1)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs),
    do:
      record
      |> cast(attrs, [
        :tenant_id,
        :domain,
        :residency,
        :cross_border_reason,
        :enabled,
        :lock_version
      ])
      |> validate_required([:tenant_id])
end
