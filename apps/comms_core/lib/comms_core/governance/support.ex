defmodule CommsCore.Governance.Support do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Audit
  alias CommsCore.Repo

  @max_limit 100

  def lock_record!(schema, id, subject) do
    Repo.one(
      from(r in schema,
        where: r.id == ^id and r.tenant_id == ^value(subject, :tenant_id),
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  def verify_version!(record, expected_version) do
    if record.lock_version != expected_version, do: Repo.rollback(:stale_version)
  end

  def governance_target_result(:ok), do: :ok
  def governance_target_result({:error, _reason}), do: {:error, :invalid_governance_target}

  def existing_idempotent(_schema, _tenant_id, nil), do: nil

  def existing_idempotent(schema, tenant_id, key),
    do: Repo.get_by(schema, tenant_id: tenant_id, idempotency_key: key)

  def maybe_equal(query, _field, nil), do: query
  def maybe_equal(query, field, value), do: where(query, [r], field(r, ^field) == ^value)

  def expected_version(attrs) do
    case value(attrs, :version) || value(attrs, :lock_version) do
      version when is_integer(version) and version > 0 ->
        {:ok, version}

      version when is_binary(version) ->
        case Integer.parse(version) do
          {number, ""} when number > 0 -> {:ok, number}
          _ -> {:error, :version_required}
        end

      _ ->
        {:error, :version_required}
    end
  end

  def enum(value, allowed) when is_atom(value), do: if(value in allowed, do: value)

  def enum(value, allowed) when is_binary(value),
    do: Enum.find(allowed, &(Atom.to_string(&1) == value))

  def enum(_, _), do: nil

  def require_reason(value) when is_binary(value) do
    if String.length(String.trim(value)) in 3..1_000,
      do: :ok,
      else: {:error, :reason_required}
  end

  def require_reason(_), do: {:error, :reason_required}

  def require_reason_for_change(attrs, field, reason_field) do
    case fetch_value(attrs, field) do
      {:ok, _value} -> require_reason(value(attrs, reason_field))
      :error -> :ok
    end
  end

  def parse_limit(value) when is_integer(value), do: value |> max(1) |> min(@max_limit)

  def parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> parse_limit(number)
      _ -> 50
    end
  end

  def parse_limit(_), do: 50

  def default(nil, value), do: value
  def default(value, _default), do: value

  def audit!(subject, action, resource_type, resource_id, metadata) do
    subject
    |> audit_command(action, resource_type, resource_id, metadata)
    |> Audit.record()
    |> audit_or_rollback()
  end

  def audit_system!(tenant_id, action, resource_id, metadata) do
    Audit.record(%{
      tenant_id: tenant_id,
      actor_user_id: nil,
      action: action,
      resource_type: "deletion_request",
      resource_id: resource_id,
      metadata: metadata,
      request_id: "worker:deletion"
    })
    |> audit_or_rollback()
  end

  def audit_command(subject, action, resource_type, resource_id, metadata) do
    %{
      tenant_id: value(subject, :tenant_id),
      actor_user_id: value(subject, :user_id),
      action: action,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: metadata,
      request_id: value(subject, :request_id)
    }
  end

  def audit_or_rollback({:ok, event}), do: event
  def audit_or_rollback({:error, reason}), do: Repo.rollback(reason)

  def transaction_result({:ok, result}), do: {:ok, result}
  def transaction_result({:error, reason}), do: {:error, reason}
  def project_result({:ok, result}, projector), do: {:ok, projector.(result)}
  def project_result({:error, _reason} = error, _projector), do: error

  def audio_revocation_ok!({:ok, _count}), do: :ok
  def audio_revocation_ok!({:error, reason}), do: Repo.rollback(reason)
  def authorization_or_rollback!(:ok), do: :ok
  def authorization_or_rollback!({:error, reason}), do: Repo.rollback(reason)
  def precondition_or_rollback!(:ok), do: :ok
  def precondition_or_rollback!({:error, reason}), do: Repo.rollback(reason)
  def owner_command_or_rollback({:ok, result}), do: result
  def owner_command_or_rollback({:error, reason}), do: Repo.rollback(reason)

  def now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  def fetch_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  def value(map, key) do
    case fetch_value(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end
end
