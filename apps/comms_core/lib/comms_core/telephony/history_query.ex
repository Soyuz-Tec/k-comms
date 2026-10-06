defmodule CommsCore.Telephony.HistoryQuery do
  @moduledoc false
  import Ecto.Query

  def parse(params) do
    with {:ok, query} <- text(value(params, :q)),
         {:ok, direction} <- direction(value(params, :direction)),
         {:ok, from} <- date(value(params, :from)),
         {:ok, to} <- date(value(params, :to)),
         true <- is_nil(from) or is_nil(to) or Date.compare(from, to) != :gt do
      {:ok, %{query: query, direction: direction, from: from, to: to}}
    else
      _ -> {:error, :invalid_phone_history_filters}
    end
  end

  def filter(query, filters) do
    query =
      if filters.query == "" do
        query
      else
        text = String.downcase(filters.query)

        where(
          query,
          [c],
          fragment(
            "strpos(lower(CASE WHEN ? = 'inbound' THEN ? ELSE ? END), ?) > 0",
            c.direction,
            c.from_number,
            c.to_number,
            ^text
          )
        )
      end

    query =
      if filters.direction,
        do: where(query, [c], c.direction == ^filters.direction),
        else: query

    query =
      if filters.from do
        timestamp = DateTime.new!(filters.from, ~T[00:00:00], "Etc/UTC")
        where(query, [c], c.started_at >= ^timestamp)
      else
        query
      end

    if filters.to do
      timestamp = DateTime.new!(filters.to, ~T[23:59:59.999999], "Etc/UTC")
      where(query, [c], c.started_at <= ^timestamp)
    else
      query
    end
  end

  defp text(nil), do: {:ok, ""}

  defp text(text) when is_binary(text) and byte_size(text) <= 80 do
    text = String.trim(text)

    {:ok,
     if(Regex.match?(~r/^[+0-9 ()\-.]+$/, text),
       do: String.replace(text, ~r/[ ()\-.]/, ""),
       else: text
     )}
  end

  defp text(_), do: :error
  defp direction(value) when value in [nil, "", "all"], do: {:ok, nil}
  defp direction("inbound"), do: {:ok, :inbound}
  defp direction("outbound"), do: {:ok, :outbound}
  defp direction(_), do: :error
  defp date(value) when value in [nil, ""], do: {:ok, nil}
  defp date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp date(_), do: :error
  defp value(params, key), do: Map.get(params, key, Map.get(params, Atom.to_string(key)))
end
