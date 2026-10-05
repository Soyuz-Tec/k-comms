defmodule CommsCore.Conversations.Federation.Room do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @derive {Inspect, only: [:id, :tenant_id]}
  schema "federation_rooms" do
    field(:tenant_id, :binary_id)
    field(:conversation_id, :binary_id)
    field(:trust_id, :binary_id)
    field(:created_by_user_id, :binary_id)
    field(:alias_localpart, :string)
    field(:provider_issuer, :string)
    field(:provider_server_name, :string)
    field(:provider_bridge_user, :string)
    field(:provider_room_box, :binary)
    field(:status, :string, default: "creating")
    field(:generation, :integer, default: 1)
    field(:lock_version, :integer, default: 1)
    field(:fenced_at, :utc_datetime_usec)
    field(:remote_cleanup_state, :string, default: "none")
    field(:local_cleanup_confirmed_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs),
    do:
      record
      |> cast(attrs, [
        :tenant_id,
        :conversation_id,
        :trust_id,
        :created_by_user_id,
        :alias_localpart,
        :provider_issuer,
        :provider_server_name,
        :provider_bridge_user,
        :provider_room_box,
        :status,
        :generation,
        :lock_version,
        :fenced_at,
        :remote_cleanup_state,
        :local_cleanup_confirmed_at
      ])
      |> validate_required([
        :tenant_id,
        :provider_issuer,
        :provider_server_name,
        :provider_bridge_user
      ])
end
