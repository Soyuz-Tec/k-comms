defmodule CommsCore.Moderation.ModerationAction do
  use CommsCore.Schema

  schema "moderation_actions" do
    belongs_to(:tenant, CommsCore.Accounts.Tenant)
    belongs_to(:moderation_case, CommsCore.Moderation.ModerationCase)
    belongs_to(:actor_user, CommsCore.Accounts.User)

    field(:action_type, Ecto.Enum,
      values: [:note, :assign, :start_review, :resolve, :dismiss, :reopen]
    )

    field(:note, :string)
    field(:metadata, :map, default: %{})
    timestamps(updated_at: false)
  end

  def changeset(action, attrs) do
    action
    |> cast(attrs, [
      :tenant_id,
      :moderation_case_id,
      :actor_user_id,
      :action_type,
      :note,
      :metadata
    ])
    |> validate_required([
      :tenant_id,
      :moderation_case_id,
      :actor_user_id,
      :action_type,
      :metadata
    ])
    |> validate_length(:note, max: 4_000)
  end
end
