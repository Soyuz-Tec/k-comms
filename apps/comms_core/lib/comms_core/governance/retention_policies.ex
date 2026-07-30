defmodule CommsCore.Governance.RetentionPolicies do
  @moduledoc false

  import Ecto.Query
  import CommsCore.Governance.Support

  alias CommsCore.Audit

  alias CommsCore.Governance.{
    Authorization,
    RetentionExecution,
    RetentionPolicy
  }

  alias CommsCore.{Conversations, Repo}

  def create_retention_policy(attrs, subject, insert_retention_job) when is_map(attrs) do
    tenant_id = value(subject, :tenant_id)
    idempotency_key = value(attrs, :idempotency_key)

    with :ok <- Authorization.authorize(subject),
         :ok <- validate_conversation(tenant_id, value(attrs, :conversation_id)) do
      case existing_idempotent(RetentionPolicy, tenant_id, idempotency_key) do
        %RetentionPolicy{} = policy ->
          {:ok, %{policy: policy, replayed: true}}

        nil ->
          case insert_retention_policy(attrs, subject) do
            {:ok, result} = success ->
              RetentionExecution.enqueue_retention_scan(
                result.policy.tenant_id,
                0,
                insert_retention_job
              )

              success

            {:error, _} = error ->
              error
          end
      end
    end
  end

  def list_retention_policies(params, subject) do
    with :ok <- Authorization.authorize(subject) do
      query =
        RetentionPolicy
        |> where([p], p.tenant_id == ^value(subject, :tenant_id))
        |> maybe_equal(:status, enum(value(params, :status), [:active, :disabled]))
        |> maybe_equal(:scope_type, enum(value(params, :scope_type), [:tenant, :conversation]))
        |> order_by([p], asc: p.name)
        |> limit(^parse_limit(value(params, :limit)))

      {:ok, Repo.all(query)}
    end
  end

  def update_retention_policy(id, attrs, subject, insert_retention_job) do
    with :ok <- Authorization.authorize(subject),
         {:ok, expected_version} <- expected_version(attrs),
         :ok <- require_reason_for_change(attrs, :status, :reason),
         :ok <- validate_conversation(value(subject, :tenant_id), value(attrs, :conversation_id)) do
      result =
        update_versioned(
          RetentionPolicy,
          id,
          expected_version,
          attrs,
          subject,
          &RetentionPolicy.changeset/2,
          [:name, :scope_type, :conversation_id, :retention_days, :delete_attachments, :status],
          "retention_policy.update"
        )

      case result do
        {:ok, policy} = success ->
          RetentionExecution.enqueue_retention_scan(policy.tenant_id, 0, insert_retention_job)
          success

        {:error, _} = error ->
          error
      end
    end
  end

  defp insert_retention_policy(attrs, subject) do
    id = Ecto.UUID.generate()

    changes = %{
      tenant_id: value(subject, :tenant_id),
      conversation_id: value(attrs, :conversation_id),
      name: value(attrs, :name),
      scope_type: value(attrs, :scope_type) || :tenant,
      retention_days: value(attrs, :retention_days),
      delete_attachments: default(value(attrs, :delete_attachments), true),
      status: value(attrs, :status) || :active,
      idempotency_key: value(attrs, :idempotency_key)
    }

    insert_with_audit(
      :policy,
      RetentionPolicy.changeset(%RetentionPolicy{id: id}, changes),
      subject,
      "retention_policy.create",
      "retention_policy",
      id,
      %{scope_type: changes.scope_type, retention_days: changes.retention_days}
    )
  end

  defp validate_conversation(_tenant_id, nil), do: :ok

  defp validate_conversation(tenant_id, id) do
    tenant_id
    |> Conversations.validate_reference(id)
    |> governance_target_result()
  end

  defp insert_with_audit(key, changeset, subject, action, resource_type, id, metadata) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(key, changeset)
    |> Audit.append(audit_command(subject, action, resource_type, id, metadata))
    |> Repo.transaction()
    |> case do
      {:ok, result} -> {:ok, %{key => Map.fetch!(result, key), replayed: false}}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp update_versioned(
         schema,
         id,
         expected_version,
         attrs,
         subject,
         changeset_fn,
         fields,
         action
       ) do
    Repo.transaction(fn ->
      record = lock_record!(schema, id, subject)
      verify_version!(record, expected_version)

      changes =
        Enum.reduce(fields, %{}, fn field, acc ->
          case fetch_value(attrs, field) do
            {:ok, value} -> Map.put(acc, field, value)
            :error -> acc
          end
        end)

      updated =
        record
        |> changeset_fn.(changes)
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> update_or_rollback()

      audit_metadata = %{
        version: updated.lock_version,
        changed_fields: Map.keys(changes)
      }

      audit_metadata =
        case value(attrs, :reason) do
          reason when is_binary(reason) -> Map.put(audit_metadata, :reason, String.trim(reason))
          _ -> audit_metadata
        end

      audit!(subject, action, "retention_policy", record.id, audit_metadata)

      updated
    end)
    |> transaction_result()
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
