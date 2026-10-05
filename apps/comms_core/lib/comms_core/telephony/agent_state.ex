defmodule CommsCore.Telephony.AgentState do
  @moduledoc false
  use CommsCore.Schema

  schema "telephony_agent_states" do
    field(:tenant_id, :binary_id)
    field(:user_id, :binary_id)
    field(:state, Ecto.Enum, values: [:ready, :away, :wrap_up], default: :ready)
    field(:expires_at, :utc_datetime_usec)
    field(:version, :integer, default: 1)
    timestamps()
  end

  def changeset(state, attrs) do
    state
    |> cast(attrs, [:tenant_id, :user_id, :state, :expires_at, :version])
    |> validate_required([:tenant_id, :user_id, :state, :expires_at, :version])
    |> validate_number(:version, greater_than: 0)
    |> unique_constraint([:tenant_id, :user_id])
    |> foreign_key_constraint(:user_id, name: :telephony_agent_state_tenant_user_fk)
  end
end
