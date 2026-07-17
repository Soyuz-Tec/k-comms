defmodule CommsCore.Governance.DeletionRequest do
  use CommsCore.Schema

  schema "deletion_requests" do
    field(:tenant_id, Ecto.UUID)
    field(:requested_by_user_id, Ecto.UUID)
    field(:subject_user_id, Ecto.UUID)
    field(:conversation_id, Ecto.UUID)
    field(:message_id, Ecto.UUID)
    field(:target_type, Ecto.Enum, values: [:user, :conversation, :message])
    field(:reason, :string)

    field(:status, Ecto.Enum,
      values: [:pending, :approved, :in_progress, :completed, :rejected, :cancelled],
      default: :pending
    )

    field(:scheduled_for, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:execution_started_at, :utc_datetime_usec)
    field(:execution_attempts, :integer, default: 0)
    field(:execution_error, :string)
    field(:evidence, :map, default: %{})
    field(:idempotency_key, :string)
    field(:lock_version, :integer, default: 1)
    timestamps()
  end

  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :tenant_id,
      :requested_by_user_id,
      :subject_user_id,
      :conversation_id,
      :message_id,
      :target_type,
      :reason,
      :status,
      :scheduled_for,
      :completed_at,
      :execution_started_at,
      :execution_attempts,
      :execution_error,
      :evidence,
      :idempotency_key
    ])
    |> validate_required([
      :tenant_id,
      :requested_by_user_id,
      :target_type,
      :reason,
      :status,
      :evidence
    ])
    |> validate_length(:reason, min: 3, max: 4_000)
    |> validate_number(:execution_attempts, greater_than_or_equal_to: 0)
    |> validate_length(:execution_error, max: 1_000)
    |> validate_evidence()
    |> validate_target()
    |> unique_constraint([:tenant_id, :idempotency_key])
  end

  defp validate_target(changeset) do
    target = get_field(changeset, :target_type)
    user_id = get_field(changeset, :subject_user_id)
    conversation_id = get_field(changeset, :conversation_id)
    message_id = get_field(changeset, :message_id)

    case {target, user_id, conversation_id, message_id} do
      {:user, id, nil, nil} when is_binary(id) -> changeset
      {:conversation, nil, id, nil} when is_binary(id) -> changeset
      {:message, nil, nil, id} when is_binary(id) -> changeset
      _ -> add_error(changeset, :target_type, "does not match the selected target")
    end
  end

  defp validate_evidence(changeset) do
    validate_change(changeset, :evidence, fn :evidence, evidence ->
      cond do
        not is_map(evidence) -> [evidence: "must be an object"]
        byte_size(Jason.encode!(evidence)) > 65_536 -> [evidence: "is too large"]
        true -> []
      end
    end)
  end
end
