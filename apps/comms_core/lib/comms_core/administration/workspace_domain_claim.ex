defmodule CommsCore.Administration.WorkspaceDomainClaim do
  @moduledoc false
  use CommsCore.Schema

  schema "workspace_domain_claims" do
    field(:tenant_id, Ecto.UUID)
    field(:challenge_actor_user_id, Ecto.UUID)
    field(:domain, :string)
    field(:challenge_token, :string)
    field(:challenge_expires_at, :utc_datetime_usec)
    field(:verified_at, :utc_datetime_usec)
    field(:proof_expires_at, :utc_datetime_usec)
    field(:discovery_enabled, :boolean, default: false)
    field(:status, Ecto.Enum, values: [:pending, :verified, :expired], default: :pending)
    field(:version, :integer, default: 1)
    timestamps()
  end

  def changeset(claim, attrs) do
    claim
    |> cast(attrs, [
      :tenant_id,
      :challenge_actor_user_id,
      :domain,
      :challenge_token,
      :challenge_expires_at,
      :verified_at,
      :proof_expires_at,
      :discovery_enabled,
      :status,
      :version
    ])
    |> validate_required([:tenant_id, :domain, :challenge_expires_at, :status, :version])
    |> validate_number(:version, greater_than: 0)
    |> validate_length(:domain, min: 4, max: 253)
    |> foreign_key_constraint(:tenant_id)
    |> unique_constraint([:tenant_id, :domain])
    |> unique_constraint(:domain, name: :workspace_domain_claims_verified_domain_index)
  end
end
