defmodule CommsCore.Telephony.Call do
  @moduledoc false
  use CommsCore.Schema

  schema "telephony_calls" do
    field(:tenant_id, :binary_id)
    field(:number_id, :binary_id)
    field(:user_id, :binary_id)
    field(:direction, Ecto.Enum, values: [:inbound, :outbound])

    field(:status, Ecto.Enum,
      values: [:ringing, :answered, :declined, :no_answer, :cancelled, :failed, :ended, :busy],
      default: :ringing
    )

    field(:from_number, :string)
    field(:to_number, :string)
    field(:extension, :string)
    field(:inbound_trunk_id, :string)
    field(:outbound_trunk_id, :string)
    field(:provider_room, :string)
    field(:provider_identity, :string)
    field(:provider_call_id, :string)
    field(:idempotency_key, :string)
    field(:answer_session_id, :binary_id)
    field(:answer_device_id, :binary_id)
    field(:app_identity, :string)
    field(:app_connected_at, :utc_datetime_usec)
    field(:app_reconnect_deadline, :utc_datetime_usec)
    field(:app_provider_sid, :string)
    field(:app_left_sid, :string)
    field(:app_event_at, :utc_datetime_usec)
    field(:app_pending_sid, :string)
    field(:app_pending_at, :utc_datetime_usec)

    field(:dispatch_status, Ecto.Enum,
      values: [:pending, :dispatching, :started],
      default: :pending
    )

    field(:dispatch_claimed_at, :utc_datetime_usec)
    field(:cleanup_claimed_at, :utc_datetime_usec)
    field(:cleanup_completed_at, :utc_datetime_usec)
    field(:started_at, :utc_datetime_usec)
    field(:answered_at, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:end_reason, :string)
    field(:route_id, :binary_id)
    field(:routing_status, :string, default: "individual")
    field(:offered_user_ids, {:array, :binary_id}, default: [])
    field(:route_expires_at, :utc_datetime_usec)
    field(:control_state, :string, default: "connected")
    field(:pbx_state, :map, default: %{})
    timestamps()
  end

  def changeset(call, attrs) do
    call
    |> cast(attrs, __schema__(:fields) -- [:inserted_at, :updated_at])
    |> validate_required([
      :tenant_id,
      :number_id,
      :user_id,
      :direction,
      :status,
      :from_number,
      :to_number,
      :extension,
      :provider_room,
      :provider_identity,
      :started_at,
      :expires_at
    ])
    |> unique_constraint(:provider_room)
    |> unique_constraint([:tenant_id, :user_id], name: :telephony_calls_one_active_per_user)
    |> unique_constraint([:tenant_id, :user_id, :idempotency_key])
    |> check_constraint(:status, name: :telephony_calls_consistent_outcome)
    |> check_constraint(:answered_at, name: :telephony_calls_consistent_times)
  end
end
