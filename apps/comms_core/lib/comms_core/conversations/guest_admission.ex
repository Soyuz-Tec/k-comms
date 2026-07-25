defmodule CommsCore.Conversations.GuestAdmission do
  @moduledoc false

  use CommsCore.Schema

  schema "conversation_guest_admissions" do
    field(:tenant_id, Ecto.UUID)
    belongs_to(:conversation, CommsCore.Conversations.Conversation)
    belongs_to(:guest_link, CommsCore.Conversations.GuestLink)
    field(:guest_user_id, Ecto.UUID)
    field(:membership_id, Ecto.UUID)
    field(:session_id, Ecto.UUID)
    field(:admitted_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    field(:converted_at, :utc_datetime_usec)
    field(:history_from_sequence, :integer)
    timestamps()
  end

  def changeset(value, attrs) do
    value
    |> cast(attrs, [
      :tenant_id,
      :conversation_id,
      :guest_link_id,
      :guest_user_id,
      :membership_id,
      :session_id,
      :admitted_at,
      :expires_at,
      :revoked_at,
      :converted_at,
      :history_from_sequence
    ])
    |> validate_required([
      :tenant_id,
      :conversation_id,
      :guest_link_id,
      :guest_user_id,
      :membership_id,
      :session_id,
      :admitted_at,
      :expires_at,
      :history_from_sequence
    ])
    |> validate_number(:history_from_sequence, greater_than_or_equal_to: 1)
    |> unique_constraint(:session_id)
    |> unique_constraint(:membership_id)
    |> check_constraint(:expires_at, name: :conversation_guest_admissions_expiry_check)
    |> check_constraint(:history_from_sequence,
      name: :conversation_guest_admissions_history_sequence_check
    )
  end
end
