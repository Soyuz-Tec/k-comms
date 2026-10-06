defmodule CommsWeb.VoicemailPresenter do
  @moduledoc false
  def message(message),
    do:
      Map.take(message, [
        :id,
        :call_id,
        :status,
        :duration_seconds,
        :retention_expires_at,
        :available_at,
        :inserted_at,
        :read_at,
        :caller_number
      ])

  def playback(signed),
    do:
      Map.take(signed, [
        :url,
        :approved_origin,
        :development_http,
        :expires_at,
        :expires_in,
        :content_type
      ])
end
