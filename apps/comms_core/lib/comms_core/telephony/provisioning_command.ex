defmodule CommsCore.Telephony.ProvisioningCommand do
  @moduledoc false
  use CommsCore.Schema
  @derive {Inspect, except: [:desired, :lease_hash]}
  schema "telephony_provisioning_commands" do
    field(:tenant_id, :binary_id)
    field(:actor_user_id, :binary_id)
    field(:actor_device_id, :binary_id)
    field(:actor_session_id, :binary_id)
    field(:request_id, :binary_id)
    field(:assignment_version, :integer)
    field(:desired, :map)
    field(:snapshot, :map, default: %{})

    field(:status, Ecto.Enum,
      values: [:inspecting, :verified, :applying, :unknown, :applied, :failed, :reconciling]
    )

    field(:failure_reason, :string)
    field(:effect_consumed, :boolean, default: false)
    field(:lease_hash, :binary)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:version, :integer, default: 1)
    timestamps()
  end
end
