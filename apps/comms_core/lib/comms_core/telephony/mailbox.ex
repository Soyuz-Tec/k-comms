defmodule CommsCore.Telephony.Mailbox do
  @moduledoc false
  use CommsCore.Schema

  schema "telephony_mailboxes" do
    field(:tenant_id, :binary_id)
    field(:number_id, :binary_id)
    field(:user_id, :binary_id)
    field(:enabled, :boolean, default: false)
    field(:retention_days, :integer, default: 30)
    field(:notice_media, :string)
    field(:version, :integer, default: 1)
    timestamps()
  end

  def changeset(box, attrs) do
    box
    |> cast(attrs, __schema__(:fields) -- [:inserted_at, :updated_at])
    |> validate_required([:tenant_id, :number_id, :user_id, :retention_days, :notice_media])
    |> validate_number(:retention_days, greater_than: 0, less_than_or_equal_to: 90)
    |> validate_format(:notice_media, ~r/^sound:[A-Za-z0-9_\/-]{1,150}$/)
    |> unique_constraint(:number_id)
  end
end
