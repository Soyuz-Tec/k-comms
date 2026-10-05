defmodule CommsCore.Conversations.PrivateRoom do
  @moduledoc false
  use CommsCore.Schema

  schema "private_matrix_rooms" do
    field(:tenant_id, Ecto.UUID)
    field(:conversation_id, Ecto.UUID)
    field(:creator_user_id, Ecto.UUID)
    field(:matrix_room_id, :string)
    field(:room_alias, :string)
    field(:provider_issuer, :string)
    field(:provider_server_name, :string)
    field(:control_matrix_user_id, :string)
    field(:provisioning_attempted_at, :utc_datetime_usec)
    field(:pending_removed_matrix_user_ids, {:array, :string}, default: [])
    field(:input_fingerprint, :binary)
    field(:historical_user_ids, {:array, Ecto.UUID}, default: [])
    field(:matrix_members, :map, default: %{})

    field(:state, Ecto.Enum,
      values: [:provisioning, :active, :rekey_pending, :purge_pending, :provider_purged, :erased],
      default: :provisioning
    )

    field(:membership_epoch, :integer, default: 1)
    field(:generation, :integer, default: 1)
    field(:purge_id, :string)
    field(:pending_removed_matrix_user_id, :string)
    field(:provider_purged_at, :utc_datetime_usec)
    field(:key_cleanup_state, :string, default: "unconfirmed")
    field(:control_claim_id, Ecto.UUID)
    field(:control_claim_expires_at, :utc_datetime_usec)
    timestamps()
  end

  def retained_changeset(%__MODULE__{} = record, attrs), do: Ecto.Changeset.change(record, attrs)
end
