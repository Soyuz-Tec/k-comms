defmodule CommsIntegrations.Calendar.Events do
  @moduledoc false
  alias CommsCore.AudioCalls.CalendarSync.{EventCommand, EventReceipt}
  alias CommsIntegrations.Calendar.{AccountBinding, Config, Http}

  @property "String {f2e0697b-6d65-4c15-a8ec-d8e1634d0d65} Name KCommsManaged"

  def event(command, opts \\ [])

  def event(%EventCommand{deadline_ms: deadline} = command, opts) when is_integer(deadline) do
    command = %{command | deadline_ms: min(deadline, System.monotonic_time(:millisecond) + 5_000)}

    with {:ok, config} <- Config.load(command.provider),
         :ok <- validate(command, config),
         :ok <-
           AccountBinding.verify(
             config,
             command.identity,
             command.access_token,
             command.deadline_ms,
             opts
           ),
         {:ok, method, url, headers, body} <- protocol(command, config) do
      case Http.request(method, url, headers, body, command.deadline_ms, opts) do
        {:ok, response} -> parse(response, command)
        {:error, _} -> receipt(command, :uncertain)
      end
    end
  end

  def event(_, _), do: {:error, :invalid_calendar_event_command}

  def external_id(:google, marker_id), do: String.replace(marker_id, "-", "")
  def marker_property, do: @property

  defp validate(command, config) do
    with true <- command.operation in [:create, :update, :delete, :get, :reconcile],
         {:ok, marker} <- Ecto.UUID.cast(command.marker_id),
         true <- marker == command.marker_id,
         true <- token?(command.access_token, 1, 16_384),
         :ok <- event_identity(command),
         :ok <- content(command, config),
         true <- command.operation != :update or token?(command.etag, 1, 1024) do
      :ok
    else
      _ -> {:error, :invalid_calendar_event_command}
    end
  end

  defp event_identity(%EventCommand{
         provider: :google,
         operation: operation,
         external_id: id,
         marker_id: marker
       }) do
    if operation in [:create, :reconcile] or id == external_id(:google, marker),
      do: :ok,
      else: :error
  end

  defp event_identity(%EventCommand{provider: :microsoft, operation: operation, external_id: id}) do
    if operation in [:create, :reconcile] or bounded?(id, 1, 2048), do: :ok, else: :error
  end

  defp event_identity(_), do: :error

  defp content(%EventCommand{operation: operation} = command, config)
       when operation in [:create, :update] do
    with true <- bounded?(command.title, 1, 800) and String.length(command.title) <= 200,
         %DateTime{} <- command.starts_at,
         %DateTime{} <- command.ends_at,
         true <- DateTime.diff(command.ends_at, command.starts_at) in 300..28_800,
         true <-
           bounded?(command.timezone, 1, 100) and
             Regex.match?(~r/^[A-Za-z0-9_+\/-]+$/, command.timezone),
         true <- authenticated_url?(command.authenticated_url, config.workspace_origin) do
      :ok
    else
      _ -> :error
    end
  end

  defp content(_, _), do: :ok

  defp authenticated_url?(url, origin) when is_binary(url) and byte_size(url) <= 2048 do
    a = URI.parse(url)
    b = URI.parse(origin)

    {a.scheme, a.host, a.port} == {b.scheme, b.host, b.port} and is_nil(a.userinfo) and
      is_nil(a.fragment) and is_binary(a.path) and
      ((is_nil(a.query) and Regex.match?(~r"\A/meetings/[0-9a-f-]{36}\z", a.path)) or
         (a.path == "/app/meetings" and is_binary(a.query) and
            Regex.match?(
              ~r"\Ameeting=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z",
              a.query
            )))
  end

  defp authenticated_url?(_, _), do: false

  defp protocol(command, config) do
    base = Config.endpoints(config).events

    headers = [
      {"authorization", "Bearer " <> command.access_token},
      {"accept", "application/json"}
    ]

    headers =
      if command.provider == :microsoft,
        do: headers ++ [{"prefer", "IdType=\"ImmutableId\""}],
        else: headers

    headers =
      if command.operation == :update, do: headers ++ [{"if-match", command.etag}], else: headers

    case command.operation do
      :create ->
        {:ok, :post, query(base, command.provider),
         headers ++ [{"content-type", "application/json"}], Jason.encode!(event_body(command))}

      :update ->
        {:ok, :patch, query(event_url(base, command), command.provider),
         headers ++ [{"content-type", "application/json"}], Jason.encode!(event_body(command))}

      :delete ->
        {:ok, :delete, query(event_url(base, command), command.provider), headers, ""}

      :get ->
        {:ok, :get, read_url(event_url(base, command), command.provider), headers, ""}

      :reconcile when command.provider == :google ->
        {:ok, :get, base <> "/" <> external_id(:google, command.marker_id), headers, ""}

      :reconcile ->
        filter =
          "singleValueExtendedProperties/Any(ep: ep/id eq '" <>
            @property <> "' and ep/value eq '" <> command.marker_id <> "')"

        query =
          URI.encode_query(%{
            "$filter" => filter,
            "$top" => "2",
            "$expand" => "singleValueExtendedProperties($filter=id eq '" <> @property <> "')"
          })

        {:ok, :get, base <> "?" <> query, headers, ""}
    end
  end

  defp event_url(base, command),
    do: base <> "/" <> URI.encode(command.external_id, &URI.char_unreserved?/1)

  defp query(url, :google), do: url <> "?sendUpdates=none"
  defp query(url, _), do: url

  defp read_url(url, :microsoft),
    do:
      url <>
        "?" <>
        URI.encode_query(%{
          "$expand" => "singleValueExtendedProperties($filter=id eq '" <> @property <> "')"
        })

  defp read_url(url, _), do: url

  defp event_body(%EventCommand{provider: :google} = command) do
    body = %{
      summary: command.title,
      description: description(command),
      start: %{dateTime: utc(command.starts_at)},
      end: %{dateTime: utc(command.ends_at)},
      extendedProperties: %{private: %{kcommsManaged: command.marker_id}}
    }

    if command.operation == :create,
      do: Map.put(body, :id, external_id(:google, command.marker_id)),
      else: body
  end

  defp event_body(%EventCommand{provider: :microsoft} = command) do
    body = %{
      subject: command.title,
      body: %{contentType: "text", content: description(command)},
      start: %{dateTime: graph_utc(command.starts_at), timeZone: "UTC"},
      end: %{dateTime: graph_utc(command.ends_at), timeZone: "UTC"},
      singleValueExtendedProperties: [%{id: @property, value: command.marker_id}]
    }

    if command.operation == :create,
      do: Map.put(body, :transactionId, command.marker_id),
      else: body
  end

  defp description(command),
    do:
      "K-Comms meeting. Open the authenticated workspace to join.\n" <>
        command.authenticated_url <> "\nSource timezone: " <> command.timezone

  defp utc(datetime), do: datetime |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()

  defp graph_utc(datetime),
    do:
      datetime
      |> DateTime.shift_zone!("Etc/UTC")
      |> DateTime.to_naive()
      |> NaiveDateTime.to_iso8601()

  defp parse(%{status: status} = response, command) do
    cond do
      status in [200, 201] and command.operation != :delete ->
        parse_success(response.body, command)

      status in [200, 204] and command.operation == :delete ->
        receipt(command, :removal_accepted)

      status == 404 and command.operation in [:get, :delete, :reconcile] ->
        receipt(command, :absent)

      status in [404, 409, 412] ->
        receipt(command, :conflict)

      status == 401 ->
        receipt(command, :reauthorization_required)

      status in [400, 403] ->
        receipt(command, :denied)

      status == 429 or status in 500..599 ->
        receipt(command, :retryable, retry_after_seconds: Http.retry_after(response.headers))

      true ->
        receipt(command, :uncertain)
    end
  end

  defp parse_success(body, %EventCommand{provider: :microsoft, operation: :reconcile} = command) do
    with {:ok, %{"value" => events} = result} <- Http.json(body),
         true <- is_list(events) and length(events) <= 2,
         {:ok, identities} <- verified_events(events, command) do
      cond do
        is_binary(result["@odata.nextLink"]) ->
          receipt(command, :duplicate, verified_ids: Enum.map(identities, & &1.id))

        identities == [] ->
          receipt(command, :absent)

        length(identities) == 1 ->
          [identity] = identities
          receipt(command, :present, external_id: identity.id, etag: identity.etag)

        true ->
          receipt(command, :duplicate, verified_ids: Enum.map(identities, & &1.id))
      end
    else
      _ -> {:error, :invalid_calendar_provider_response}
    end
  end

  defp parse_success(body, command) do
    with {:ok, event} <- Http.json(body),
         {:ok, identity} <- verified_event(event, command) do
      outcome = if command.operation in [:create, :update], do: :applied, else: :present
      receipt(command, outcome, external_id: identity.id, etag: identity.etag)
    end
  rescue
    _ -> {:error, :invalid_calendar_provider_response}
  end

  defp verified_events(events, command) do
    Enum.reduce_while(events, {:ok, []}, fn event, {:ok, acc} ->
      case verified_event(event, command) do
        {:ok, identity} -> {:cont, {:ok, acc ++ [identity]}}
        error -> {:halt, error}
      end
    end)
  end

  defp verified_event(event, %EventCommand{provider: :google} = command) when is_map(event) do
    marker = get_in(event, ["extendedProperties", "private", "kcommsManaged"])

    if marker == command.marker_id and event["id"] == external_id(:google, command.marker_id) and
         token?(event["etag"], 1, 1024) do
      {:ok, %{id: event["id"], etag: event["etag"]}}
    else
      {:error, :calendar_managed_event_binding_failed}
    end
  end

  defp verified_event(event, %EventCommand{provider: :microsoft} = command) when is_map(event) do
    properties = event["singleValueExtendedProperties"]

    valid_marker =
      is_list(properties) and length(properties) <= 20 and
        Enum.count(
          properties,
          &(is_map(&1) and &1["id"] == @property and &1["value"] == command.marker_id)
        ) == 1

    id = event["id"]
    exact = command.operation in [:create, :reconcile] or id == command.external_id

    if valid_marker and exact and bounded?(id, 1, 2048) and
         token?(event["@odata.etag"], 1, 1024) do
      {:ok, %{id: id, etag: event["@odata.etag"]}}
    else
      {:error, :calendar_managed_event_binding_failed}
    end
  end

  defp verified_event(_, _), do: {:error, :calendar_managed_event_binding_failed}

  defp receipt(command, outcome, attrs \\ []),
    do:
      {:ok,
       struct!(EventReceipt, Keyword.merge([provider: command.provider, outcome: outcome], attrs))}

  defp token?(value, min, max),
    do:
      is_binary(value) and byte_size(value) in min..max and
        Regex.match?(~r/\A[\x21-\x7e]+\z/, value)

  defp bounded?(value, min, max),
    do:
      is_binary(value) and byte_size(value) in min..max and
        not String.contains?(value, ["\r", "\n", "\0"])
end
