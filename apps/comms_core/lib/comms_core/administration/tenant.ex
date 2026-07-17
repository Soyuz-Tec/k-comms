defmodule CommsCore.Administration.Tenant do
  use CommsCore.Schema

  schema "tenants" do
    field(:name, :string)
    field(:slug, :string)
    field(:status, Ecto.Enum, values: [:active, :suspended, :deleting], default: :active)
    timestamps()
  end

  def changeset(value, attrs) do
    value
    |> cast(attrs, [:name, :slug, :status])
    |> update_change(:slug, &normalize_slug/1)
    |> validate_required([:name, :slug, :status])
    |> validate_length(:name, min: 2, max: 120)
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/)
    |> validate_length(:slug, min: 2, max: 80)
    |> unique_constraint(:slug)
  end

  defp normalize_slug(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp normalize_slug(value), do: value
end
