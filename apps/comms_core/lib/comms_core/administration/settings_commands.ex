defmodule CommsCore.Administration.SettingsCommands do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Administration.{
    AuthorizationPolicy,
    CallLifecycleCommand,
    CallLifecyclePort,
    CallLifecycleReceipt,
    Projector,
    Tenant,
    TenantSettings
  }

  alias CommsCore.Audit
  alias CommsCore.{AdmissionQuotas, Repo, RuntimePorts}

  def get_view(subject) do
    with {:ok, result} <- get_settings(subject) do
      {:ok, project_result(result)}
    end
  end

  def update_view(attrs, subject) do
    with {:ok, result} <- update_settings(attrs, subject) do
      {:ok, project_result(result)}
    end
  end

  def get_settings(subject) do
    with :ok <- AuthorizationPolicy.authorize(:administer_tenant, subject),
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

  def update_settings(attrs, subject) when is_map(attrs) and is_map(subject) do
    tenant_id = value(subject, :tenant_id)

    with :ok <- AuthorizationPolicy.authorize(:manage_tenant_settings, subject),
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
          Map.take(attrs, [
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

        revoke_disabled_media!(tenant, current, updated_settings)

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

  defp revoke_disabled_media!(tenant, current, updated) do
    if current.allow_audio_calls and not updated.allow_audio_calls do
      tenant.id
      |> CallLifecycleCommand.tenant_media_disabled(:audio, "tenant_audio_disabled")
      |> CallLifecyclePort.revoke_tenant_media()
      |> call_lifecycle_ok!()
    end

    if current.allow_video_calls and not updated.allow_video_calls do
      tenant.id
      |> CallLifecycleCommand.tenant_media_disabled(:video, "tenant_video_disabled")
      |> CallLifecyclePort.revoke_tenant_media()
      |> call_lifecycle_ok!()
    end
  end

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

  defp project_result(result) do
    %{
      tenant: Projector.tenant(result.tenant),
      settings: Projector.settings(result.settings)
    }
  end

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
