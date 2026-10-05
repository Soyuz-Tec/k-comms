defmodule CommsCore.Accounts.MemberWorkspace do
  @moduledoc false
  use CommsCore.Schema

  schema "member_workspaces" do
    field(:tenant_id, Ecto.UUID)
    field(:user_id, Ecto.UUID)
    field(:contact_ids, {:array, Ecto.UUID}, default: [])
    field(:contact_groups, :map, default: %{"items" => []})
    field(:profile_reviewed_at, :utc_datetime_usec)
    field(:onboarding_dismissed_at, :utc_datetime_usec)
    field(:lock_version, :integer, default: 1)
    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :tenant_id,
      :user_id,
      :contact_ids,
      :contact_groups,
      :profile_reviewed_at,
      :onboarding_dismissed_at,
      :lock_version
    ])
    |> validate_required([:tenant_id, :user_id])
    |> foreign_key_constraint(:user_id, name: :member_workspaces_tenant_user_fk)
    |> unique_constraint([:tenant_id, :user_id])
    |> check_constraint(:contact_ids, name: :member_workspaces_contact_limit)
    |> check_constraint(:contact_groups, name: :member_workspaces_group_shape)
  end
end
