defmodule CommsCore.Telephony.ControlCommand do
  @moduledoc false
  use CommsCore.Schema

  schema "telephony_control_commands" do
    field(:tenant_id, :binary_id)
    field(:call_id, :binary_id)
    field(:user_id, :binary_id)
    field(:session_id, :binary_id)
    field(:device_id, :binary_id)

    field(:action, Ecto.Enum,
      values: [
        :dtmf,
        :blind_transfer,
        :hold,
        :resume,
        :consult_transfer,
        :complete_transfer,
        :cancel_transfer,
        :voicemail
      ]
    )

    field(:status, Ecto.Enum,
      values: [:pending, :dispatching, :submitted, :failed, :unknown],
      default: :pending
    )

    field(:idempotency_key, :string)
    field(:payload_hash, :string)
    field(:destination, :string)
    field(:claimed_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:failure_reason, :string)
    field(:notice_completed_at, :utc_datetime_usec)
    field(:notice_event_id, :string)
    timestamps()
  end

  def changeset(command, attrs) do
    command
    |> cast(attrs, __schema__(:fields) -- [:inserted_at, :updated_at])
    |> validate_required([
      :tenant_id,
      :call_id,
      :user_id,
      :action,
      :status,
      :idempotency_key,
      :payload_hash,
      :expires_at
    ])
    |> unique_constraint([:call_id, :idempotency_key])
  end
end
