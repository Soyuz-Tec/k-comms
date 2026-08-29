defmodule CommsCore.Administration.PolicyQueries do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Administration.{
    AuthorizationPolicy,
    CallPolicy,
    ConversationContentPolicy,
    RetentionDefaults,
    Tenant,
    TenantSettings
  }

  alias CommsCore.Repo

  def call_policy(tenant_id) when is_binary(tenant_id) do
    with {:ok, tenant_id} <- Ecto.UUID.cast(tenant_id) do
      {:ok, project_call_policy(tenant_id)}
    else
      :error -> {:error, :forbidden}
    end
  end

  def call_policy(_tenant_id), do: {:error, :forbidden}

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

  def conversation_content_policy(subject) when is_map(subject) do
    tenant_id = value(subject, :tenant_id)

    with :ok <- AuthorizationPolicy.authorize(:read_capabilities, subject) do
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

    with :ok <- AuthorizationPolicy.authorize(:read_capabilities, subject) do
      settings = Repo.get_by(TenantSettings, tenant_id: tenant_id) || %TenantSettings{}

      {:ok,
       %{
         allow_public_channels: settings.allow_public_channels,
         allow_audio_calls: settings.allow_audio_calls,
         allow_video_calls: settings.allow_video_calls,
         allow_immersive_mode: immersive_mode_allowed?(settings),
         message_edit_window_seconds: settings.message_edit_window_seconds,
         max_attachment_bytes: settings.max_attachment_bytes
       }}
    end
  end

  # The tenant-side half of immersive eligibility. Immersive Mode is only ever
  # entered after joining a call, so a tenant with no call kind enabled can
  # never reach it -- this is a real precondition, not a placeholder for one.
  #
  # It is deliberately derived rather than stored. A dedicated tenant_settings
  # column is the right shape once immersive needs to be withheld from a tenant
  # that *does* have calls, which staged rollout will eventually want; adding
  # the column before that need is real would ship a migration and an admin
  # control that nothing yet decides the value of.
  defp immersive_mode_allowed?(settings) do
    settings.allow_audio_calls == true or settings.allow_video_calls == true
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

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
