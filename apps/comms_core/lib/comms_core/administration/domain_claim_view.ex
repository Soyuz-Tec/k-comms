defmodule CommsCore.Administration.DomainClaimView do
  @moduledoc "Administrative domain proof state. Challenge values are privileged."
  @enforce_keys [:id, :domain, :version, :status, :discovery_enabled, :challenge_name]
  defstruct [
    :id,
    :domain,
    :version,
    :status,
    :discovery_enabled,
    :challenge_name,
    :challenge_value,
    :challenge_expires_at,
    :verified_at,
    :proof_expires_at
  ]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          domain: String.t(),
          version: pos_integer(),
          status: :pending | :verified | :expired,
          discovery_enabled: boolean(),
          challenge_name: String.t(),
          challenge_value: String.t() | nil,
          challenge_expires_at: DateTime.t(),
          verified_at: DateTime.t() | nil,
          proof_expires_at: DateTime.t() | nil
        }
end
