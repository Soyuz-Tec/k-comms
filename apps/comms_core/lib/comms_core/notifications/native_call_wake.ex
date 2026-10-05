defmodule CommsCore.Notifications.NativeCallWake do
  use CommsCore.Schema

  schema "native_call_wakes" do
    field(:tenant_id, Ecto.UUID)
    field(:user_id, Ecto.UUID)
    field(:device_id, Ecto.UUID)
    field(:session_id, Ecto.UUID)
    field(:registration_id, Ecto.UUID)
    field(:registration_version, :integer)
    field(:user_version, :integer)
    field(:owner, :string)
    field(:call_id, Ecto.UUID)
    field(:conversation_id, Ecto.UUID)
    field(:source_event_id, Ecto.UUID)
    field(:status, :string, default: "pending")
    field(:expires_at, :utc_datetime_usec)
    field(:attempted_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)
    field(:disabled_at, :utc_datetime_usec)
    timestamps()
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, __schema__(:fields) -- [:id, :inserted_at, :updated_at])
    |> validate_required([
      :tenant_id,
      :user_id,
      :device_id,
      :session_id,
      :registration_id,
      :registration_version,
      :user_version,
      :owner,
      :call_id,
      :source_event_id,
      :status,
      :expires_at
    ])
    |> validate_inclusion(:owner, ["conversation", "telephony"])
    |> validate_inclusion(:status, [
      "pending",
      "dispatching",
      "sent",
      "uncertain",
      "consumed",
      "expired",
      "revoked",
      "failed"
    ])
    |> unique_constraint([:registration_id, :registration_version, :call_id],
      name: :native_call_wake_generation_unique
    )
  end
end
