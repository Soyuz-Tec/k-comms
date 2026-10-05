defmodule CommsCore.Governance.HistoryProjection do
  @moduledoc false
  alias CommsCore.Accounts
  alias CommsCore.Governance.{HistoryActor, HistoryEvent, Projector}

  @proof_keys ~w(derived_erasure_version media_erasure_version meeting_erasure_version writer_fence_erasure_version)
  @count_keys ~w(messages_tombstoned attachments_deleted deleted_object_count)
  @maximum_integer 9_007_199_254_740_991
  @statuses %{
    "deletion_request.create" => :pending,
    "deletion_request.approved" => :approved,
    "deletion_request.rejected" => :rejected,
    "deletion_request.cancelled" => :cancelled,
    "deletion_request.claim" => :in_progress,
    "deletion_request.failure" => :in_progress,
    "deletion_request.writer_fence_repair_queued" => :in_progress,
    "deletion_request.completed" => :completed,
    "deletion_request.derived_content_repaired" => :completed
  }

  def actions, do: Map.keys(@statuses)

  def events(tenant_id, events) do
    ids = events |> Enum.map(& &1.actor_user_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    people = tenant_id |> Accounts.resolve_user_views(ids) |> Map.new(&{&1.id, &1})
    Enum.map(events, &event(&1, people))
  end

  def request(request) do
    view = Projector.deletion_request(request)
    %{view | execution_error: error(view.execution_error), evidence: summary(view.evidence)}
  end

  def coverage(page) do
    %{
      state:
        cond do
          is_nil(page.earliest_at) ->
            :unavailable

          page.origin_present and not page.snapshot_truncated and
              page.captured_count == page.retained_count ->
            :available

          true ->
            :partial
        end,
      retained_only: true,
      version_lineage: :unproven,
      origin_present: page.origin_present,
      earliest_at: page.earliest_at,
      snapshot_truncated: page.snapshot_truncated,
      captured_count: page.captured_count,
      retained_count: page.retained_count,
      maximum_events: 5_000
    }
  end

  defp event(event, people) do
    metadata = event.metadata || %{}
    evidence = value(metadata, "evidence")
    evidence = if is_map(evidence), do: evidence, else: %{}
    proof_versions = Map.merge(integers(metadata, @proof_keys), integers(evidence, @proof_keys))
    counts = Map.merge(integers(metadata, @count_keys), integers(evidence, @count_keys))

    %HistoryEvent{
      id: event.id,
      actor: actor(event.actor_user_id, people),
      inserted_at: event.inserted_at,
      action: event.action,
      status: @statuses[event.action],
      attempt: integer(value(metadata, "attempt")),
      error_code: error(value(metadata, "error_code")),
      version: positive_integer(value(metadata, "version")),
      proof_versions: proof_versions,
      counts: counts
    }
  end

  defp actor(nil, _people), do: %HistoryActor{kind: :system}

  defp actor(id, people) do
    case Map.get(people, id) do
      nil -> %HistoryActor{kind: :unavailable}
      person -> %HistoryActor{kind: :user, user_id: person.id, display_name: person.display_name}
    end
  end

  defp summary(metadata) when is_map(metadata),
    do: Map.merge(integers(metadata, @proof_keys), integers(metadata, @count_keys))

  defp summary(_), do: %{}

  defp integers(metadata, keys) do
    Enum.reduce(keys, %{}, fn key, result ->
      case integer(value(metadata, key)) do
        nil -> result
        number -> Map.put(result, key, number)
      end
    end)
  end

  defp value(map, key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {atom, value} when is_atom(atom) -> if Atom.to_string(atom) == key, do: value
        _ -> nil
      end)
  end

  defp integer(value) when is_integer(value) and value in 0..@maximum_integer, do: value
  defp integer(_), do: nil
  defp positive_integer(value) when is_integer(value) and value in 1..@maximum_integer, do: value
  defp positive_integer(_), do: nil
  defp error(nil), do: nil
  defp error("provider_failure"), do: :provider_failure
  defp error("writer_fence_repair_pending"), do: :verification_pending
  defp error("verification_pending"), do: :verification_pending
  defp error(_), do: :unavailable
end
