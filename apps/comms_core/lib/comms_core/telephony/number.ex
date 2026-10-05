defmodule CommsCore.Telephony.Number do
  @moduledoc false
  use CommsCore.Schema

  schema "telephony_numbers" do
    field(:tenant_id, :binary_id)
    field(:user_id, :binary_id)
    field(:phone_number, :string)
    field(:extension, :string)
    field(:inbound_trunk_id, :string)
    field(:outbound_trunk_id, :string)
    field(:lock_version, :integer, default: 1)
    timestamps()
  end

  def changeset(number, attrs) do
    number
    |> cast(attrs, [
      :tenant_id,
      :user_id,
      :phone_number,
      :extension,
      :inbound_trunk_id,
      :outbound_trunk_id
    ])
    |> validate_required([
      :tenant_id,
      :user_id,
      :phone_number,
      :extension,
      :inbound_trunk_id,
      :outbound_trunk_id
    ])
    |> validate_format(:phone_number, ~r/^\+[1-9][0-9]{7,14}$/)
    |> validate_format(:extension, ~r/^[0-9]{2,8}$/)
    |> validate_format(:inbound_trunk_id, ~r/^[A-Za-z0-9_-]{2,200}$/)
    |> validate_format(:outbound_trunk_id, ~r/^[A-Za-z0-9_-]{2,200}$/)
    |> unique_constraint(:tenant_id)
    |> unique_constraint(:phone_number)
    |> foreign_key_constraint(:user_id, name: :telephony_numbers_tenant_user_fk)
  end
end
