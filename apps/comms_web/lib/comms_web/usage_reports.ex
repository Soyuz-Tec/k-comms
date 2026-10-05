defmodule CommsWeb.UsageReports do
  @moduledoc "Application composition of content-free canonical owner projections."
  alias CommsCore.{Accounts, Attachments, AudioCalls, Conversations, Messaging, Telephony}

  @type date_range :: %{from: Date.t(), through: Date.t()}
  @type source_key :: :identity | :conversations | :messages | :attachments | :calls | :telephony
  @type projection ::
          Accounts.UsageProjection.t()
          | Conversations.UsageProjection.t()
          | Messaging.UsageProjection.t()
          | Attachments.UsageProjection.t()
          | AudioCalls.UsageProjection.t()
          | Telephony.UsageProjection.t()
  @type source :: {source_key(), (date_range(), map() -> {:ok, projection()} | {:error, atom()})}

  @spec range(map()) :: {:ok, date_range()} | {:error, :invalid_usage_query}
  def range(params) when is_map(params) do
    with true <- Enum.all?(Map.keys(params), &(&1 in ["from", "through"])),
         {:ok, through} <- parse_date(Map.get(params, "through", Date.to_iso8601(Date.utc_today()))),
         {:ok, from} <- parse_date(Map.get(params, "from", Date.to_iso8601(Date.add(through, -29)))),
         true <- Date.diff(through, from) in 0..30,
         true <- Date.compare(through, Date.utc_today()) != :gt do
      {:ok, %{from: from, through: through}}
    else
      _ -> {:error, :invalid_usage_query}
    end
  end

  def range(_), do: {:error, :invalid_usage_query}

  @spec collect(map(), map(), [source()]) :: {:ok, map()} | {:error, atom()}
  def collect(params, subject, sources \\ sources()) do
    with {:ok, range} <- range(params),
         :ok <- authorize(subject),
         {:ok, projections} <- collect_sources(sources, range, subject) do
      {:ok,
       %{
         range: %{from: range.from, through: range.through, time_zone: "UTC"},
         observed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
         coverage: "currently_retained_records",
         lifetime_complete: false,
         sources: projections
       }}
    end
  end

  @spec json(map(), map()) :: {:ok, binary()} | {:error, atom()}
  def json(params, subject) do
    with {:ok, report} <- collect(params, subject) do
      disclose(subject, fn -> {:ok, Jason.encode!(%{data: report})} end)
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :usage_report_unavailable}
  end

  @spec export(map(), map()) :: {:ok, binary(), map()} | {:error, atom()}
  def export(params, subject) do
    with {:ok, report} <- collect(params, subject),
         {:ok, body} <- disclose(subject, fn -> csv(report) end) do
      {:ok, body,
       %{
         from: Date.to_iso8601(report.range.from),
         through: Date.to_iso8601(report.range.through),
         observed_at: DateTime.to_iso8601(report.observed_at),
         unavailable_sources:
           Enum.count(report.sources, fn {_key, value} -> value.status == "unavailable" end)
       }}
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :usage_report_unavailable}
  end

  @spec csv(map()) :: {:ok, binary()} | {:error, :usage_report_too_large}
  def csv(report) do
    columns =
      ~w(source status date metric value observed_at earliest_retained_at coverage range_from range_through time_zone)

    rows =
      report.sources
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.flat_map(fn {key, source} -> csv_rows(key, source, report) end)

    if length(rows) > 5_000 do
      {:error, :usage_report_too_large}
    else
      {:ok,
       Enum.map_join([columns | rows], "\r\n", fn cells ->
         Enum.map_join(cells, ",", &csv_cell/1)
       end) <> "\r\n"}
    end
  end

  defp sources do
    [
      {:identity,
       fn range, subject ->
         Accounts.usage_projection(
           %Accounts.UsageQuery{
             tenant_id: subject.tenant_id,
             from: range.from,
             through: range.through
           },
           subject
         )
       end},
      {:conversations,
       fn range, subject ->
         Conversations.usage_projection(
           %Conversations.UsageQuery{
             tenant_id: subject.tenant_id,
             from: range.from,
             through: range.through
           },
           subject
         )
       end},
      {:messages,
       fn range, subject ->
         Messaging.usage_projection(
           %Messaging.UsageQuery{
             tenant_id: subject.tenant_id,
             from: range.from,
             through: range.through
           },
           subject
         )
       end},
      {:attachments,
       fn range, subject ->
         Attachments.usage_projection(
           %Attachments.UsageQuery{
             tenant_id: subject.tenant_id,
             from: range.from,
             through: range.through
           },
           subject
         )
       end},
      {:calls,
       fn range, subject ->
         AudioCalls.usage_projection(
           %AudioCalls.UsageQuery{
             tenant_id: subject.tenant_id,
             from: range.from,
             through: range.through
           },
           subject
         )
       end},
      {:telephony,
       fn range, subject ->
         Telephony.usage_projection(
           %Telephony.UsageQuery{
             tenant_id: subject.tenant_id,
             from: range.from,
             through: range.through
           },
           subject
         )
       end}
    ]
  end

  defp authorize(subject) do
    case Accounts.access_grant(subject) do
      {:ok, %{account_type: :human, access_scope: :workspace, role: role, step_up_recent?: recent}}
      when role in [:owner, :admin] ->
        if recent, do: :ok, else: {:error, :step_up_required}

      _ ->
        {:error, :forbidden}
    end
  end

  defp collect_sources(sources, range, subject) do
    Enum.reduce_while(sources, {:ok, %{}}, fn {key, source}, {:ok, results} ->
      case source_result(key, source, range, subject) do
        {:ok, projection} ->
          {:cont, {:ok, Map.put(results, key, %{status: "available", data: projection})}}

        {:error, reason} when reason in [:forbidden, :step_up_required, :invalid_usage_query] ->
          {:halt, {:error, reason}}

        :unavailable ->
          {:cont, {:ok, Map.put(results, key, %{status: "unavailable", data: nil})}}
      end
    end)
  end

  defp source_result(key, source, range, subject) do
    case source.(range, subject) do
      {:ok, projection} ->
        projection_data(key, projection)

      {:error, reason} when reason in [:forbidden, :step_up_required, :invalid_usage_query] ->
        {:error, reason}

      _ ->
        :unavailable
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> :unavailable
  end

  defp projection_data(:identity, %Accounts.UsageProjection{} = value),
    do: {:ok, Map.from_struct(value)}

  defp projection_data(:conversations, %Conversations.UsageProjection{} = value),
    do: {:ok, Map.from_struct(value)}

  defp projection_data(:messages, %Messaging.UsageProjection{} = value),
    do: {:ok, Map.from_struct(value)}

  defp projection_data(:attachments, %Attachments.UsageProjection{} = value),
    do: {:ok, Map.from_struct(value)}

  defp projection_data(:calls, %AudioCalls.UsageProjection{} = value),
    do: {:ok, Map.from_struct(value)}

  defp projection_data(:telephony, %Telephony.UsageProjection{} = value),
    do: {:ok, Map.from_struct(value)}

  defp projection_data(_, _), do: :unavailable

  defp disclose(subject, encoder) do
    Accounts.with_usage_report_disclosure(subject, encoder)
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :usage_report_unavailable}
  end

  defp parse_date(value) when is_binary(value) do
    if Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, value),
      do: Date.from_iso8601(value),
      else: {:error, :invalid_usage_query}
  end

  defp parse_date(_), do: {:error, :invalid_usage_query}

  defp csv_rows(key, %{status: "unavailable"}, report),
    do: [row(key, "unavailable", nil, nil, nil, nil, nil, report)]

  defp csv_rows(key, %{status: "available", data: data}, report) do
    current =
      data.current
      |> Enum.sort()
      |> Enum.map(fn {metric, value} ->
        row(
          key,
          "available",
          "current",
          metric,
          value,
          data.observed_at,
          data.earliest_retained_at,
          report
        )
      end)

    daily =
      Enum.flat_map(data.daily, fn day ->
        day.metrics
        |> Enum.sort()
        |> Enum.map(fn {metric, value} ->
          row(
            key,
            "available",
            day.date,
            metric,
            value,
            data.observed_at,
            data.earliest_retained_at,
            report
          )
        end)
      end)

    current ++ daily
  end

  defp row(key, status, date, metric, value, observed, earliest, report) do
    [
      key,
      status,
      date,
      metric,
      value,
      observed,
      earliest,
      report.coverage,
      report.range.from,
      report.range.through,
      "UTC"
    ]
  end

  defp csv_cell(nil), do: "\"\""
  defp csv_cell(%Date{} = value), do: csv_cell(Date.to_iso8601(value))
  defp csv_cell(%DateTime{} = value), do: csv_cell(DateTime.to_iso8601(value))

  defp csv_cell(value) do
    text = to_string(value)

    text =
      if String.starts_with?(text, ["=", "+", "-", "@", "\t", "\r", "\n"]),
        do: "'" <> text,
        else: text

    "\"" <> String.replace(text, "\"", "\"\"") <> "\""
  end
end
