defmodule CommsWeb.CalendarPresenter do
  @moduledoc false
  alias CommsCore.AudioCalls.CalendarSync.{ConnectionView, ExportView}

  def connection(%ConnectionView{} = view),
    do: %{
      id: view.id,
      provider: view.provider,
      version: view.version,
      status: view.status,
      consent_generation: view.consent_generation,
      new_exports_allowed: view.new_exports_allowed?,
      permission_status: view.permission_status,
      provider_grant_revocation: view.provider_grant_revocation,
      managed_events_pending_removal: view.managed_events_pending_removal,
      last_success_at: instant(view.last_success_at),
      safe_reason: view.safe_reason
    }

  def export(%ExportView{} = view),
    do: %{
      id: view.id,
      connection_id: view.connection_id,
      meeting_id: view.meeting_id,
      version: view.version,
      status: view.status,
      desired_meeting_version: view.desired_meeting_version,
      applied_meeting_version: view.applied_meeting_version,
      occurrence_count: view.occurrence_count,
      safe_reason: view.safe_reason
    }

  def metadata(result),
    do: %{
      mode: result.mode,
      policy: %{export_allowed: result.policy.export_allowed?, version: result.policy.version},
      providers:
        Enum.map(result.providers, fn provider ->
          %{
            provider: provider.provider,
            configured: provider.configured?,
            qualified: provider.qualified?,
            safe_reason: provider.safe_reason
          }
        end)
    }

  def instant(nil), do: nil
  def instant(%DateTime{} = value), do: DateTime.to_iso8601(value)
end
