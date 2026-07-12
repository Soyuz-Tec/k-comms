defmodule CommsCore.Moderation.ModerationCase do
  use CommsCore.Schema

  schema "moderation_cases" do
    belongs_to(:tenant, CommsCore.Accounts.Tenant)
    belongs_to(:reporter_user, CommsCore.Accounts.User)
    belongs_to(:subject_user, CommsCore.Accounts.User)
    belongs_to(:conversation, CommsCore.Conversations.Conversation)
    belongs_to(:message, CommsCore.Messaging.Message)
    belongs_to(:assigned_to_user, CommsCore.Accounts.User)
    field(:category, :string)
    field(:summary, :string)
    field(:details, :string)
    field(:priority, Ecto.Enum, values: [:low, :normal, :high, :urgent], default: :normal)
    field(:status, Ecto.Enum, values: [:open, :in_review, :resolved, :dismissed], default: :open)
    field(:resolved_at, :utc_datetime_usec)
    field(:idempotency_key, :string)
    field(:lock_version, :integer, default: 1)
    timestamps()
  end

  def changeset(moderation_case, attrs) do
    moderation_case
    |> cast(attrs, [
      :tenant_id,
      :reporter_user_id,
      :subject_user_id,
      :conversation_id,
      :message_id,
      :assigned_to_user_id,
      :category,
      :summary,
      :details,
      :priority,
      :status,
      :resolved_at,
      :idempotency_key
    ])
    |> validate_required([:tenant_id, :reporter_user_id, :category, :summary, :priority, :status])
    |> validate_length(:category, min: 2, max: 80)
    |> validate_length(:summary, min: 3, max: 240)
    |> validate_length(:details, max: 10_000)
    |> validate_length(:idempotency_key, max: 200)
    |> validate_target()
    |> unique_constraint([:tenant_id, :reporter_user_id, :idempotency_key],
      name: :moderation_cases_idem_unique
    )
  end

  defp validate_target(changeset) do
    if Enum.any?([:subject_user_id, :conversation_id, :message_id], &get_field(changeset, &1)) do
      changeset
    else
      add_error(changeset, :message_id, "a subject user, conversation, or message is required")
    end
  end
end
