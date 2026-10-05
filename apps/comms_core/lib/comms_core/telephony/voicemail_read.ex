defmodule CommsCore.Telephony.VoicemailRead do
  @moduledoc false
  use CommsCore.Schema
  @primary_key false
  schema "telephony_voicemail_reads" do
    field(:tenant_id, :binary_id)
    field(:voicemail_id, :binary_id, primary_key: true)
    field(:user_id, :binary_id, primary_key: true)
    field(:read_at, :utc_datetime_usec)
  end

  def changeset(row, attrs),
    do:
      row
      |> cast(attrs, [:tenant_id, :voicemail_id, :user_id, :read_at])
      |> validate_required([:tenant_id, :voicemail_id, :user_id, :read_at])
end
