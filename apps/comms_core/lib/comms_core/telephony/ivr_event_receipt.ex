defmodule CommsCore.Telephony.IvrEventReceipt do
  @moduledoc false
  use CommsCore.Schema

  schema "telephony_ivr_event_receipts" do
    field(:tenant_id, :binary_id)
    field(:run_id, :binary_id)
    field(:event_id, :string)
    field(:body_fingerprint, :string)
    field(:step, :integer)
    field(:event_type, :string)
    timestamps(updated_at: false)
  end

  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [:tenant_id, :run_id, :event_id, :body_fingerprint, :step, :event_type])
    |> validate_required([:tenant_id, :run_id, :event_id, :body_fingerprint, :step, :event_type])
    |> validate_format(:event_id, ~r/^[0-9a-f]{64}$/)
    |> validate_format(:body_fingerprint, ~r/^[0-9a-f]{64}$/)
    |> validate_inclusion(:event_type, [
      "PlaybackFinished",
      "ChannelDtmfReceived",
      "ChannelDestroyed"
    ])
    |> unique_constraint(:event_id)
  end
end
