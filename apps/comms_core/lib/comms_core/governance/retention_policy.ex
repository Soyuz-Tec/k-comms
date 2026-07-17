defmodule CommsCore.Governance.RetentionPolicy do
  use CommsCore.Schema

  schema "retention_policies" do
    field(:tenant_id, Ecto.UUID)
    field(:conversation_id, Ecto.UUID)
    field(:name, :string)
    field(:scope_type, Ecto.Enum, values: [:tenant, :conversation], default: :tenant)
    field(:retention_days, :integer)
    field(:delete_attachments, :boolean, default: true)
    field(:status, Ecto.Enum, values: [:active, :disabled], default: :active)
    field(:idempotency_key, :string)
    field(:lock_version, :integer, default: 1)
    timestamps()
  end

  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [
      :tenant_id,
      :conversation_id,
      :name,
      :scope_type,
      :retention_days,
      :delete_attachments,
      :status,
      :idempotency_key
    ])
    |> validate_required([
      :tenant_id,
      :name,
      :scope_type,
      :retention_days,
      :delete_attachments,
      :status
    ])
    |> validate_length(:name, min: 2, max: 120)
    |> validate_number(:retention_days, greater_than: 0, less_than_or_equal_to: 36_500)
    |> validate_scope()
    |> unique_constraint([:tenant_id, :idempotency_key])
    |> unique_constraint(:tenant_id, name: :retention_policies_one_active_tenant_policy)
    |> unique_constraint([:tenant_id, :conversation_id],
      name: :retention_policies_one_active_conversation_policy
    )
  end

  defp validate_scope(changeset) do
    case {get_field(changeset, :scope_type), get_field(changeset, :conversation_id)} do
      {:tenant, nil} -> changeset
      {:conversation, id} when is_binary(id) -> changeset
      _ -> add_error(changeset, :conversation_id, "does not match the selected scope")
    end
  end
end
