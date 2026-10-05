defmodule CommsCore.Telephony.Route do
  @moduledoc false
  use CommsCore.Schema

  schema "telephony_routes" do
    field(:tenant_id, :binary_id)
    field(:number_id, :binary_id)
    field(:name, :string)
    field(:mode, Ecto.Enum, values: [:queue, :shared_line])
    field(:policy, Ecto.Enum, values: [:round_robin, :simultaneous])
    field(:member_ids, {:array, :binary_id}, default: [])
    field(:max_waiting, :integer, default: 20)
    field(:max_wait_seconds, :integer, default: 120)
    field(:enabled, :boolean, default: false)
    field(:cursor, :integer, default: 0)
    field(:version, :integer, default: 1)
    timestamps()
  end

  def changeset(route, attrs) do
    route
    |> cast(attrs, __schema__(:fields) -- [:inserted_at, :updated_at])
    |> validate_required([
      :tenant_id,
      :number_id,
      :name,
      :mode,
      :policy,
      :member_ids,
      :max_waiting,
      :max_wait_seconds,
      :enabled
    ])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:member_ids, min: 1, max: 25)
    |> validate_number(:max_waiting, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_number(:max_wait_seconds,
      greater_than_or_equal_to: 10,
      less_than_or_equal_to: 600
    )
    |> validate_queue_policy()
    |> unique_constraint(:number_id)
  end

  defp validate_queue_policy(changeset) do
    if get_field(changeset, :mode) == :queue and get_field(changeset, :policy) != :round_robin,
      do: add_error(changeset, :policy, "queues require round-robin assignment"),
      else: changeset
  end
end
