defmodule CommsWeb.TelephonyPresenter do
  @moduledoc false

  @call_fields [
    :id,
    :direction,
    :status,
    :from_number,
    :to_number,
    :extension,
    :started_at,
    :answered_at,
    :ended_at,
    :connected_seconds,
    :can_answer,
    :can_join,
    :can_end,
    :active_on_this_device,
    :end_reason
  ]
  @number_fields [:id, :phone_number, :extension, :user_id]
  @admin_number_fields @number_fields ++ [:inbound_trunk_id, :outbound_trunk_id]

  def call(call), do: Map.take(call, @call_fields)

  def config(config) do
    fields = if config.can_manage, do: @admin_number_fields, else: @number_fields

    %{
      enabled: config.enabled,
      configured: config.configured,
      provider_ready: config.provider_ready,
      line_assigned: config.line_assigned,
      provider: "livekit_sip",
      number: if(config.number, do: Map.take(config.number, fields), else: nil),
      can_manage: config.can_manage
    }
  end
end
