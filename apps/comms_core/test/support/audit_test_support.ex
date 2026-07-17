defmodule CommsCore.Audit.TestSupport do
  @moduledoc false

  alias CommsCore.Audit.{AuditEvent, Event}
  alias CommsCore.Repo

  def insert!(attrs) when is_map(attrs) do
    event = %AuditEvent{id: value(attrs, :id)}

    event
    |> AuditEvent.changeset(attrs)
    |> maybe_put_inserted_at(value(attrs, :inserted_at))
    |> Repo.insert!()
    |> Event.from_schema()
  end

  defp maybe_put_inserted_at(changeset, nil), do: changeset

  defp maybe_put_inserted_at(changeset, inserted_at),
    do: Ecto.Changeset.put_change(changeset, :inserted_at, inserted_at)

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
