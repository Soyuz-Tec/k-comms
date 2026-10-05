defmodule CommsCore.Accounts.MemberWorkspaceView do
  @moduledoc "Private, versioned member organization; groups grant no access."
  @enforce_keys [:version, :contacts, :groups, :onboarding, :limits, :observed_at]
  defstruct [:version, :contacts, :groups, :onboarding, :limits, :observed_at]

  @type t :: %__MODULE__{
          version: non_neg_integer(),
          contacts: [CommsCore.Accounts.DirectoryPersonView.t()],
          groups: [%{id: Ecto.UUID.t(), name: String.t(), member_ids: [Ecto.UUID.t()]}],
          onboarding: %{
            dismissed_at: DateTime.t() | nil,
            profile_reviewed_at: DateTime.t() | nil,
            active_devices: non_neg_integer(),
            has_teammates: boolean()
          },
          limits: %{
            contacts: pos_integer(),
            groups: pos_integer(),
            members_per_group: pos_integer()
          },
          observed_at: DateTime.t()
        }
end
