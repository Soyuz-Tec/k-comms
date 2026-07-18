defmodule CommsCore.Governance.LegalHold do
  use CommsCore.Schema

  schema "legal_holds" do
    field(:tenant_id, Ecto.UUID)
    field(:created_by_user_id, Ecto.UUID)
    field(:subject_user_id, Ecto.UUID)
    field(:conversation_id, Ecto.UUID)
    field(:name, :string)
    field(:reason, :string)
    field(:scope_type, Ecto.Enum, values: [:tenant, :user, :conversation])
    field(:status, Ecto.Enum, values: [:active, :released], default: :active)
    field(:starts_at, :utc_datetime_usec)
    field(:released_at, :utc_datetime_usec)
    field(:idempotency_key, :string)
    field(:lock_version, :integer, default: 1)
    timestamps()
  end

  def changeset(hold, attrs) do
    hold
    |> cast(attrs, [
      :tenant_id,
      :created_by_user_id,
      :subject_user_id,
      :conversation_id,
      :name,
      :reason,
      :scope_type,
      :status,
      :starts_at,
      :released_at,
      :idempotency_key
    ])
    |> validate_required([
      :tenant_id,
      :created_by_user_id,
      :name,
      :reason,
      :scope_type,
      :status,
      :starts_at
    ])
    |> validate_length(:name, min: 2, max: 160)
    |> validate_length(:reason, min: 3, max: 4_000)
    |> validate_scope()
    |> unique_constraint([:tenant_id, :idempotency_key])
  end

  defp validate_scope(changeset) do
    scope = get_field(changeset, :scope_type)
    user_id = get_field(changeset, :subject_user_id)
    conversation_id = get_field(changeset, :conversation_id)

    case {scope, user_id, conversation_id} do
      {:tenant, nil, nil} -> changeset
      {:user, id, nil} when is_binary(id) -> changeset
      {:conversation, nil, id} when is_binary(id) -> changeset
      _ -> add_error(changeset, :scope_type, "does not match the selected target")
    end
  end
end
