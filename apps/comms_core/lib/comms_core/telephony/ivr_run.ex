defmodule CommsCore.Telephony.IvrRun do
  @moduledoc false
  use CommsCore.Schema

  schema "telephony_ivr_runs" do
    field(:tenant_id, :binary_id)
    field(:call_id, :binary_id)
    field(:menu_id, :binary_id)
    field(:menu_version, :integer)
    field(:snapshot, :map)

    field(:phase, Ecto.Enum,
      values: [
        :pending,
        :preparing,
        :playing,
        :awaiting_digit,
        :selected,
        :routing,
        :destination_pending,
        :destination_connecting,
        :unknown,
        :completed,
        :failed,
        :cancelled
      ],
      default: :pending
    )

    field(:step, :integer, default: 1)
    field(:retries, :integer, default: 0)
    field(:selected_target, :map)
    field(:bindings, :map, default: %{})
    field(:claimed_at, :utc_datetime_usec)
    field(:effect_claim_fingerprint, :string)
    field(:effect_started_at, :utc_datetime_usec)
    field(:prompt_completed_at, :utc_datetime_usec)
    field(:digit_deadline, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:failure_reason, :string)
    timestamps()
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, __schema__(:fields) -- [:inserted_at, :updated_at])
    |> validate_required([
      :tenant_id,
      :call_id,
      :menu_id,
      :menu_version,
      :snapshot,
      :phase,
      :step,
      :retries,
      :expires_at
    ])
    |> validate_number(:step, greater_than: 0, less_than_or_equal_to: 3)
    |> validate_number(:retries, greater_than_or_equal_to: 0, less_than_or_equal_to: 2)
    |> unique_constraint(:call_id)
  end
end
