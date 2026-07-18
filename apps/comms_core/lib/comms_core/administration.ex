defmodule CommsCore.Administration do
  import Ecto.Query

  alias CommsCore.Administration.{
    AuthorizationPolicy,
    CallLifecycleCommand,
    CallLifecyclePort,
    CallLifecycleReceipt,
    CallPolicy,
    ConversationContentPolicy,
    Invitations,
    Projector,
    RetentionDefaults,
    Tenant,
    TenantSettings,
    TenantView
  }

  alias CommsCore.Audit
  alias CommsCore.{AdmissionQuotas, Repo, RuntimePorts}

  @default_limit 50
  @max_limit 100

  def create_invitation(attrs, subject), do: Invitations.create(attrs, subject)
  def list_invitations(subject, status \\ nil), do: Invitations.list(subject, status)
  def revoke_invitation(id, attrs, subject), do: Invitations.revoke(id, attrs, subject)
  def accept_invitation(attrs), do: Invitations.accept(attrs)

  @doc """
  Authorizes access to tenant capabilities through the TenantAdministration boundary.
  """
  @spec authorize_read_capabilities(map()) :: :ok | {:error, :forbidden}
  def authorize_read_capabilities(subject) when is_map(subject) do
    AuthorizationPolicy.authorize(:read_capabilities, subject)
  end

  @doc """
  Authorizes ordinary tenant administration that does not require step-up.
  """
  @spec authorize_administer_tenant(map()) :: :ok | {:error, :forbidden}
  def authorize_administer_tenant(subject) when is_map(subject) do
    AuthorizationPolicy.authorize(:administer_tenant, subject)
  end

  @doc """
  Authorizes invitation lifecycle changes owned by TenantAdministration.
  """
  @spec authorize_manage_invitations(map()) ::
          :ok | {:error, :forbidden | :step_up_required}
  def authorize_manage_invitations(subject) when is_map(subject) do
    AuthorizationPolicy.authorize(:manage_invitations, subject)
  end

  @doc """
  Authorizes tenant-settings changes owned by TenantAdministration.
  """
  @spec authorize_manage_settings(map()) ::
          :ok | {:error, :forbidden | :step_up_required}
  def authorize_manage_settings(subject) when is_map(subject) do
    AuthorizationPolicy.authorize(:manage_tenant_settings, subject)
  end

  @doc """
  Authorizes tenant audit reads exposed by TenantAdministration.
  """
  @spec authorize_audit_tenant(map()) ::
          :ok | {:error, :forbidden | :step_up_required}
  def authorize_audit_tenant(subject) when is_map(subject) do
    AuthorizationPolicy.authorize(:audit_tenant, subject)
  end

  @doc """
  Adds a tenant-owned bootstrap insert to a caller-owned transaction.

  The operation returns a `TenantView`; the Tenant persistence schema never
  crosses this owner boundary.
  """
  def append_bootstrap_tenant(multi, operation, attrs)
      when is_atom(operation) and is_map(attrs) do
    Ecto.Multi.run(multi, operation, fn repo, _changes ->
      persist_bootstrap_tenant(repo, attrs)
    end)
  end

  @doc false
  def create_bootstrap_tenant(attrs) when is_map(attrs) do
    if Repo.in_transaction?(),
      do: persist_bootstrap_tenant(Repo, attrs),
      else: {:error, :transaction_required}
  end

  @doc false
  def get_bootstrap_tenant_by_slug(slug) when is_binary(slug) do
    Tenant
    |> Repo.get_by(slug: slug)
    |> case do
      %Tenant{} = tenant -> Projector.tenant(tenant)
      nil -> nil
    end
  end

  @doc false
  def any_tenant?, do: Repo.exists?(Tenant)

  @doc """
  Returns an active tenant as a stable owner projection.

  Missing, suspended, deleting, and malformed tenant identifiers are deliberately
  indistinguishable to callers outside TenantAdministration.
  """
  @spec active_tenant(Ecto.UUID.t()) ::
          {:ok, TenantView.t()} | {:error, :tenant_unavailable}
  def active_tenant(tenant_id) when is_binary(tenant_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(tenant_id),
         %Tenant{} = tenant <- Repo.get_by(Tenant, id: tenant_id, status: :active) do
      {:ok, Projector.tenant(tenant)}
    else
      _ -> {:error, :tenant_unavailable}
    end
  end

  def active_tenant(_tenant_id), do: {:error, :tenant_unavailable}

  @doc """
  Returns the Ecto-free media capability policy consumed by Calls.

  Calls resolves the active identity first. A missing settings row therefore
  retains TenantAdministration's enabled-by-default media behavior without
  exposing `TenantSettings`.
  """
  @spec call_policy(Ecto.UUID.t()) :: {:ok, CallPolicy.t()} | {:error, :forbidden}
  def call_policy(tenant_id) when is_binary(tenant_id) do
    with {:ok, tenant_id} <- Ecto.UUID.cast(tenant_id) do
      {:ok, project_call_policy(tenant_id)}
    else
      :error -> {:error, :forbidden}
    end
  end

  def call_policy(_tenant_id), do: {:error, :forbidden}

  @doc """
  Locks the active tenant before returning its Calls capability policy.

  The caller must own the transaction. The shared tenant lock serializes with
  tenant-settings updates, which acquire the tenant row for update before
  changing media capability flags.
  """
  @spec lock_call_policy(Ecto.UUID.t()) ::
          {:ok, CallPolicy.t()} | {:error, :forbidden | :transaction_required}
  def lock_call_policy(tenant_id) when is_binary(tenant_id) do
    if Repo.in_transaction?() do
      with {:ok, tenant_id} <- Ecto.UUID.cast(tenant_id),
           %Tenant{} <-
             Repo.one(
               from(tenant in Tenant,
                 where: tenant.id == ^tenant_id and tenant.status == :active,
                 lock: "FOR SHARE"
               )
             ) do
        {:ok, project_call_policy(tenant_id)}
      else
        _ -> {:error, :forbidden}
      end
    else
      {:error, :transaction_required}
    end
  end

  def lock_call_policy(_tenant_id), do: {:error, :forbidden}

  @doc """
  Returns an active tenant by slug as a stable owner projection.

  Missing, suspended, and deleting tenants are deliberately indistinguishable
  to callers outside TenantAdministration.
  """
  @spec active_tenant_by_slug(String.t()) ::
          {:ok, TenantView.t()} | {:error, :tenant_unavailable}
  def active_tenant_by_slug(slug) when is_binary(slug) do
    case Repo.get_by(Tenant, slug: slug, status: :active) do
      %Tenant{} = tenant -> {:ok, Projector.tenant(tenant)}
      nil -> {:error, :tenant_unavailable}
    end
  end

  def active_tenant_by_slug(_slug), do: {:error, :tenant_unavailable}

  @doc """
  Returns the tenant's optional default retention period as a stable projection.

  Callers receive no TenantSettings persistence details. A tenant without a
  persisted settings row has no configured default retention period.
  """
  @spec retention_defaults(Ecto.UUID.t()) ::
          {:ok, RetentionDefaults.t()} | {:error, :invalid_tenant_id}
  def retention_defaults(tenant_id) when is_binary(tenant_id) do
    case Ecto.UUID.cast(tenant_id) do
      {:ok, _uuid} ->
        default_retention_days =
          TenantSettings
          |> where([settings], settings.tenant_id == ^tenant_id)
          |> select([settings], settings.default_retention_days)
          |> Repo.one()

        {:ok,
         %RetentionDefaults{
           tenant_id: tenant_id,
           default_retention_days: default_retention_days
         }}

      :error ->
        {:error, :invalid_tenant_id}
    end
  end

  def retention_defaults(_tenant_id), do: {:error, :invalid_tenant_id}

  def get_tenant_settings_view(subject) do
    with {:ok, result} <- get_tenant_settings(subject) do
      {:ok, project_tenant_settings_result(result)}
    end
  end

  def update_tenant_settings_view(attrs, subject) do
    with {:ok, result} <- update_tenant_settings(attrs, subject) do
      {:ok, project_tenant_settings_result(result)}
    end
  end

  @doc """
  Returns the minimal tenant policy consumed by ConversationContent.

  The caller must hold ordinary tenant capability access. Missing persisted
  settings use the same defaults as tenant administration without exposing the
  TenantSettings schema or unrelated capabilities.
  """
  @spec conversation_content_policy(map()) ::
          {:ok, ConversationContentPolicy.t()} | {:error, :forbidden}
  def conversation_content_policy(subject) when is_map(subject) do
    tenant_id = value(subject, :tenant_id)

    with :ok <- authorize_read_capabilities(subject) do
      settings = Repo.get_by(TenantSettings, tenant_id: tenant_id) || %TenantSettings{}

      {:ok,
       %ConversationContentPolicy{
         tenant_id: tenant_id,
         message_edit_window_seconds: settings.message_edit_window_seconds,
         max_attachment_bytes: settings.max_attachment_bytes
       }}
    end
  end

  def conversation_content_policy(_subject), do: {:error, :forbidden}

  def member_capabilities(subject) do
    tenant_id = value(subject, :tenant_id)

    with :ok <- authorize_read_capabilities(subject) do
      settings = Repo.get_by(TenantSettings, tenant_id: tenant_id) || %TenantSettings{}

      {:ok,
       %{
         allow_public_channels: settings.allow_public_channels,
         allow_audio_calls: settings.allow_audio_calls,
         allow_video_calls: settings.allow_video_calls,
         message_edit_window_seconds: settings.message_edit_window_seconds,
         max_attachment_bytes: settings.max_attachment_bytes
       }}
    end
  end

  def get_tenant_settings(subject) do
    with :ok <- authorize_administer_tenant(subject),
         %Tenant{} = tenant <- Repo.get(Tenant, value(subject, :tenant_id)) do
      settings =
        Repo.get_by(TenantSettings, tenant_id: tenant.id) ||
          %TenantSettings{tenant_id: tenant.id}

      {:ok, %{tenant: tenant, settings: settings}}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def update_tenant_settings(attrs, subject) when is_map(attrs) and is_map(subject) do
    tenant_id = value(subject, :tenant_id)

    with :ok <- authorize_manage_settings(subject),
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
            :allow_audio_calls,
            :allow_video_calls,
            :message_edit_window_seconds,
            :max_attachment_bytes,
            :default_retention_days,
            :max_active_users,
            :max_active_conversations,
            :max_conversation_members,
            "allow_public_channels",
            "allow_audio_calls",
            "allow_video_calls",
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

        if current.allow_audio_calls and not updated_settings.allow_audio_calls do
          CallLifecycleCommand.tenant_media_disabled(
            tenant.id,
            :audio,
            "tenant_audio_disabled"
          )
          |> CallLifecyclePort.revoke_tenant_media()
          |> call_lifecycle_ok!()
        end

        if current.allow_video_calls and not updated_settings.allow_video_calls do
          CallLifecycleCommand.tenant_media_disabled(
            tenant.id,
            :video,
            "tenant_video_disabled"
          )
          |> CallLifecyclePort.revoke_tenant_media()
          |> call_lifecycle_ok!()
        end

        audit!(subject, "tenant.settings_update", "tenant", tenant.id, %{
          version: updated_settings.lock_version,
          changed_fields: changed_fields(attrs)
        })

        enqueue_retention!(tenant.id)

        %{tenant: updated_tenant, settings: updated_settings}
      end)
      |> transaction_result()
    end
  end

  def list_audit_events(params, subject) when is_map(params) do
    with :ok <- authorize_audit_tenant(subject),
         {:ok, before} <- optional_cursor(value(params, :cursor) || value(params, :before)),
         {:ok, after_timestamp} <- optional_datetime(value(params, :after)) do
      limit = parse_limit(value(params, :limit))

      Repo.transaction(fn ->
        events =
          Audit.list(%{
            tenant_id: value(subject, :tenant_id),
            action: value(params, :action),
            resource_type: value(params, :resource_type),
            actor_user_id: value(params, :actor_user_id),
            request_id: value(params, :request_id),
            before: before,
            after: after_timestamp,
            limit: limit
          })

        audit!(subject, "audit.read", "tenant", value(subject, :tenant_id), %{
          filters: audit_filters(params),
          returned_count: length(events)
        })

        %{events: events, limit: limit, next_cursor: cursor_for(List.last(events))}
      end)
      |> transaction_result()
    end
  end

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
      ~w(name allow_public_channels allow_audio_calls allow_video_calls message_edit_window_seconds max_attachment_bytes default_retention_days max_active_users max_active_conversations max_conversation_members)

    attrs
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(&1 in allowed))
    |> Enum.sort()
  end

  defp audit!(subject, action, resource_type, resource_id, metadata) do
    Audit.record(%{
      tenant_id: value(subject, :tenant_id),
      actor_user_id: value(subject, :user_id),
      action: action,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: metadata,
      request_id: value(subject, :request_id)
    })
    |> audit_or_rollback()
  end

  defp audit_or_rollback({:ok, event}), do: event
  defp audit_or_rollback({:error, reason}), do: Repo.rollback(reason)

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

  defp call_lifecycle_ok!({:ok, %CallLifecycleReceipt{}}), do: :ok
  defp call_lifecycle_ok!({:error, reason}), do: Repo.rollback(reason)

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp project_tenant_settings_result(result) do
    %{
      tenant: CommsCore.Administration.Projector.tenant(result.tenant),
      settings: CommsCore.Administration.Projector.settings(result.settings)
    }
  end

  defp project_call_policy(tenant_id) do
    settings =
      Repo.get_by(TenantSettings, tenant_id: tenant_id) ||
        %TenantSettings{tenant_id: tenant_id}

    %CallPolicy{
      tenant_id: tenant_id,
      allow_audio_calls: settings.allow_audio_calls,
      allow_video_calls: settings.allow_video_calls
    }
  end

  defp persist_bootstrap_tenant(repo, attrs) do
    %Tenant{id: value(attrs, :id)}
    |> Tenant.changeset(%{
      name: value(attrs, :name),
      slug: value(attrs, :slug),
      status: :active
    })
    |> repo.insert()
    |> case do
      {:ok, tenant} -> {:ok, Projector.tenant(tenant)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
