defmodule CommsCore.Accounts.UsageProjection do
  @moduledoc "Content-free observed aggregates over currently retained owner records."
  @enforce_keys [:observed_at, :earliest_retained_at, :current, :daily]
  defstruct [:observed_at, :earliest_retained_at, :current, :daily]

  @type metric :: :active_humans | :active_services | :humans_created | :services_created
  @type counts :: %{optional(metric()) => non_neg_integer()}
  @type day :: %{required(:date) => Date.t(), required(:metrics) => counts()}
  @type t :: %__MODULE__{
          observed_at: DateTime.t(),
          earliest_retained_at: DateTime.t() | nil,
          current: counts(),
          daily: [day()]
        }
end
