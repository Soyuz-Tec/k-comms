defmodule CommsCore.Administration do
  import Ecto.Query

  alias CommsCore.Accounts.Tenant
  alias CommsCore.Administration.TenantSettings
  alias CommsCore.Audit.AuditEvent
  alias CommsCore.{AdmissionQuotas, Authorization, Repo, RuntimePorts}

  @default_limit 50
  @max_limit 100
  def member_capabilities(subject) do
    tenant_id = value(subject, :tenant_id)

    with :ok <- Authorization.authorize(:read_tenant_capabilities, subject, %{id: tenant_id}) do
      settings = Repo.get_by(TenantSettings, tenant_id: tenant_id) || %TenantSettings{}

      {:ok,
       %{
         allow_public_channels: settings.allow_public_channels,
         message_edit_window_seconds: settings.message_edit_window_seconds,
         max_attachment_bytes: settings.max_attachment_bytes
       }}
    end
  end

  def get_tenant_settings(subject) do
    with :ok <-
           Authorization.authorize(:administer_tenant, subject, %{id: value(subject, :tenant_id)}),
         %Tenant{} = tenant <- Repo.get(Tenant, value(subject, :tenant_id)) do
      settings =
        Repo.get_by(TenantSettings, tenant_id: tenant.id) ||
          %TenantSettings{tenant_id: tenant.id}

      {:ok, %{tenant: tenant, settings: settings, usage: AdmissionQuotas.usage(tenant.id)}}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def update_tenant_settings(attrs, subject) when is_map(attrs) and is_map(subject) do
    tenant_id = value(subject, :tenant_id)

    with :ok <- Authorization.authorize(:manage_tenant_settings, subject, %{id: tenant_id}),
         {:ok, expected_version} <- expected_version(attrs) do
      Repo.transaction(fn ->
        quota_ok!(AdmissionQuotas.lock_tenant(tenant_id))

        tenant =
          Repo.one(from(t in Tenant, where: t.id == ^tenant_id, lock: "FOR UPDATE")) ||
            Repo.rollback(:not_found)

        settings =
          Repo.one(
            from(s in TenantSettings,
              where: s.tenant_id == ^tenant_id,
              lock: "FOR UPDATE"
            )
          )

        current = settings || %TenantSettings{tenant_id: tenant_id, lock_version: 1}
        if current.lock_version != expected_version, do: Repo.rollback(:stale_version)

        settings_attrs =
          attrs
          |> Map.take([
            :allow_public_channels,
            :message_edit_window_seconds,
            :max_attachment_bytes,
            :default_retention_days,
            :max_active_users,
            :max_active_conversations,
            :max_conversation_members,
            "allow_public_channels",
            "message_edit_window_seconds",
            "max_attachment_bytes",
            "default_retention_days",
            "max_active_users",
            "max_active_conversations",
            "max_conversation_members"
          ])

        updated_settings =
          if settings do
            settings
            |> TenantSettings.changeset(settings_attrs)
            |> Ecto.Changeset.optimistic_lock(:lock_version)
            |> update_or_rollback()
          else
            %TenantSettings{tenant_id: tenant_id, lock_version: expected_version + 1}
            |> TenantSettings.changeset(settings_attrs)
            |> insert_or_rollback()
          end

        updated_tenant =
          case value(attrs, :name) do
            nil -> tenant
            name -> tenant |> Tenant.changeset(%{name: name}) |> update_or_rollback()
          end

        audit!(subject, "tenant.settings_update", "tenant", tenant.id, %{
          version: updated_settings.lock_version,
          changed_fields: changed_fields(attrs)
        })

        enqueue_retention!(tenant.id)

        %{
          tenant: updated_tenant,
          settings: updated_settings,
          usage: AdmissionQuotas.usage(tenant_id)
        }
      end)
      |> transaction_result()
    end
  end

  def list_audit_events(params, subject) when is_map(params) do
    with :ok <- Authorization.authorize(:audit_tenant, subject, %{id: value(subject, :tenant_id)}),
         {:ok, before} <- optional_cursor(value(params, :cursor) || value(params, :before)),
         {:ok, after_timestamp} <- optional_datetime(value(params, :after)) do
      limit = parse_limit(value(params, :limit))

      Repo.transaction(fn ->
        query =
          AuditEvent
          |> where([e], e.tenant_id == ^value(subject, :tenant_id))
          |> maybe_equal(:action, value(params, :action))
          |> maybe_equal(:resource_type, value(params, :resource_type))
          |> maybe_equal(:actor_user_id, value(params, :actor_user_id))
          |> maybe_equal(:request_id, value(params, :request_id))
          |> maybe_before(before)
          |> maybe_after(after_timestamp)
          |> order_by([e], desc: e.inserted_at, desc: e.id)
          |> limit(^limit)

        events = Repo.all(query)

        audit!(subject, "audit.read", "tenant", value(subject, :tenant_id), %{
          filters: audit_filters(params),
          returned_count: length(events)
        })

        %{events: events, limit: limit, next_cursor: cursor_for(List.last(events))}
      end)
      |> transaction_result()
    end
  end

  defp maybe_equal(query, _field, nil), do: query
  defp maybe_equal(query, _field, ""), do: query
  defp maybe_equal(query, field, value), do: where(query, [e], field(e, ^field) == ^value)

  defp maybe_before(query, nil), do: query

  defp maybe_before(query, {timestamp, nil}),
    do: where(query, [e], e.inserted_at < ^timestamp)

  defp maybe_before(query, {timestamp, id}) do
    where(
      query,
      [e],
      e.inserted_at < ^timestamp or (e.inserted_at == ^timestamp and e.id < ^id)
    )
  end

  defp maybe_after(query, nil), do: query
  defp maybe_after(query, timestamp), do: where(query, [e], e.inserted_at >= ^timestamp)

  defp optional_datetime(nil), do: {:ok, nil}
  defp optional_datetime(%DateTime{} = value), do: {:ok, value}

  defp optional_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> {:ok, timestamp}
      _ -> {:error, :invalid_datetime}
    end
  end

  defp optional_datetime(_), do: {:error, :invalid_datetime}

  defp optional_cursor(nil), do: {:ok, nil}

  defp optional_cursor(value) when is_binary(value) do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         {:ok, %{"inserted_at" => timestamp, "id" => id}} <- Jason.decode(decoded),
         {:ok, parsed, _offset} <- DateTime.from_iso8601(timestamp),
         {:ok, _uuid} <- Ecto.UUID.cast(id) do
      {:ok, {parsed, id}}
    else
      _ ->
        case optional_datetime(value) do
          {:ok, parsed} -> {:ok, {parsed, nil}}
          {:error, _} -> {:error, :invalid_cursor}
        end
    end
  end

  defp optional_cursor(_), do: {:error, :invalid_cursor}

  defp cursor_for(nil), do: nil

  defp cursor_for(event) do
    %{inserted_at: DateTime.to_iso8601(event.inserted_at), id: event.id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp audit_filters(params) do
    params
    |> Map.take([
      :action,
      :resource_type,
      :actor_user_id,
      :request_id,
      "action",
      "resource_type",
      "actor_user_id",
      "request_id"
    ])
  end

  defp parse_limit(value) when is_integer(value), do: value |> max(1) |> min(@max_limit)

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> parse_limit(number)
      _ -> @default_limit
    end
  end

  defp parse_limit(_), do: @default_limit

  defp expected_version(attrs) do
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

  defp changed_fields(attrs) do
    allowed =
      ~w(name allow_public_channels message_edit_window_seconds max_attachment_bytes default_retention_days max_active_users max_active_conversations max_conversation_members)

    attrs
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(&1 in allowed))
    |> Enum.sort()
  end

  defp audit!(subject, action, resource_type, resource_id, metadata) do
    %AuditEvent{}
    |> AuditEvent.changeset(%{
      tenant_id: value(subject, :tenant_id),
      actor_user_id: value(subject, :user_id),
      action: action,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: metadata,
      request_id: value(subject, :request_id)
    })
    |> insert_or_rollback()
  end

  defp enqueue_retention!(tenant_id) do
    %{"tenant_id" => tenant_id}
    |> Oban.Job.new(
      worker: RuntimePorts.job_worker_name!(:retention),
      queue: :default,
      unique: [
        period: 300,
        fields: [:worker, :args],
        states: [:available, :scheduled, :retryable]
      ]
    )
    |> Repo.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp quota_ok!(:ok), do: :ok
  defp quota_ok!({:error, reason}), do: Repo.rollback(reason)

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
