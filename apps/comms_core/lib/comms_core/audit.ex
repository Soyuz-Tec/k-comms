defmodule CommsCore.Audit do
  @moduledoc """
  Public audit command and query boundary.

  Audit persistence schemas are internal. Callers append validated commands or
  consume `CommsCore.Audit.Event` projections.
  """

  import Ecto.Query

  alias CommsCore.Audit.{AuditEvent, Error, Event}
  alias CommsCore.Repo

  @equal_filters [
    :id,
    :tenant_id,
    :action,
    :resource_type,
    :actor_user_id,
    :request_id,
    :resource_id
  ]

  @typedoc "Validated input accepted by `record/1` and `append/2`."
  @type record_command :: %{
          required(:tenant_id) => Ecto.UUID.t(),
          required(:action) => String.t(),
          required(:resource_type) => String.t(),
          required(:resource_id) => Ecto.UUID.t(),
          required(:metadata) => map(),
          optional(:actor_user_id) => Ecto.UUID.t() | nil,
          optional(:request_id) => String.t() | nil,
          optional(:operation) => Ecto.Multi.name()
        }

  @spec record(record_command()) :: {:ok, Event.t()} | {:error, Error.t()}
  def record(attrs) when is_map(attrs), do: insert(Repo, attrs)

  defp insert(repo, attrs) do
    %AuditEvent{}
    |> AuditEvent.changeset(attrs)
    |> repo.insert()
    |> project_result()
  end

  @spec append(Ecto.Multi.t(), record_command()) :: Ecto.Multi.t()
  def append(%Ecto.Multi{} = multi, attrs) when is_map(attrs) do
    {operation, command} = Map.pop(attrs, :operation, :audit)

    Ecto.Multi.run(multi, operation, fn repo, _changes -> insert(repo, command) end)
  end

  @spec list(map()) :: [Event.t()]
  def list(filters) when is_map(filters) do
    filters
    |> require_tenant!()
    |> query()
    |> order(filters)
    |> maybe_limit(value(filters, :limit))
    |> Repo.all()
    |> Enum.map(&Event.from_schema/1)
  end

  @spec count(map()) :: non_neg_integer()
  def count(filters) when is_map(filters) do
    filters
    |> require_tenant!()
    |> query()
    |> Repo.aggregate(:count)
  end

  @spec get_by(map()) :: Event.t() | nil
  def get_by(filters) when is_map(filters) do
    filters
    |> require_tenant!()
    |> query()
    |> Repo.one()
    |> project()
  end

  @spec get_by!(map()) :: Event.t()
  def get_by!(filters) when is_map(filters) do
    filters
    |> require_tenant!()
    |> query()
    |> Repo.one!()
    |> Event.from_schema()
  end

  defp query(filters) do
    Enum.reduce(@equal_filters, AuditEvent, fn field_name, query ->
      case value(filters, field_name) do
        nil -> query
        "" -> query
        filter -> where(query, [event], field(event, ^field_name) == ^filter)
      end
    end)
    |> maybe_after(value(filters, :after))
    |> maybe_before(value(filters, :before))
    |> maybe_search(value(filters, :q))
  end

  defp maybe_after(query, nil), do: query

  defp maybe_after(query, %DateTime{} = timestamp),
    do: where(query, [event], event.inserted_at >= ^timestamp)

  defp maybe_before(query, nil), do: query

  defp maybe_before(query, {%DateTime{} = timestamp, nil}),
    do: where(query, [event], event.inserted_at < ^timestamp)

  defp maybe_before(query, {%DateTime{} = timestamp, id}) when is_binary(id) do
    where(
      query,
      [event],
      event.inserted_at < ^timestamp or (event.inserted_at == ^timestamp and event.id < ^id)
    )
  end

  defp maybe_before(query, %DateTime{} = timestamp),
    do: where(query, [event], event.inserted_at < ^timestamp)

  defp maybe_search(query, nil), do: query
  defp maybe_search(query, ""), do: query

  defp maybe_search(query, text) when is_binary(text) do
    pattern = "%#{escape_like(text)}%"

    where(
      query,
      [event],
      ilike(event.action, ^pattern) or ilike(event.resource_type, ^pattern) or
        ilike(event.request_id, ^pattern) or
        fragment("CAST(? AS text) ILIKE ?", event.resource_id, ^pattern) or
        fragment("CAST(? AS text) ILIKE ?", event.actor_user_id, ^pattern)
    )
  end

  defp order(query, filters) do
    case value(filters, :order) do
      :asc -> order_by(query, [event], asc: event.inserted_at, asc: event.id)
      _ -> order_by(query, [event], desc: event.inserted_at, desc: event.id)
    end
  end

  defp maybe_limit(query, value) when is_integer(value) and value > 0, do: limit(query, ^value)
  defp maybe_limit(query, _value), do: query

  defp escape_like(value),
    do: String.replace(value, ["%", "_", "\\"], fn char -> "\\" <> char end)

  defp project_result({:ok, event}), do: {:ok, Event.from_schema(event)}
  defp project_result({:error, changeset}), do: {:error, Error.from_changeset(changeset)}
  defp project(nil), do: nil
  defp project(event), do: Event.from_schema(event)

  defp require_tenant!(filters) do
    case value(filters, :tenant_id) do
      tenant_id when is_binary(tenant_id) and tenant_id != "" -> filters
      _ -> raise ArgumentError, "Audit queries require tenant_id"
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
