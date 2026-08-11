defmodule CommsWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :comms_web

  @websocket_max_frame_size 1_048_576

  socket("/socket", CommsWeb.UserSocket,
    websocket: [
      connect_info: [:peer_data, :x_headers],
      max_frame_size: @websocket_max_frame_size
    ],
    longpoll: false
  )

  def websocket_max_frame_size, do: @websocket_max_frame_size

  # Establish trusted edge metadata before any response or route policy reads
  # the effective request scheme.
  plug(CommsWeb.Plugs.TrustedProxy)
  plug(CommsWeb.Plugs.SecurityHeaders)
  plug(CommsWeb.Plugs.StaticCacheHeaders)
  plug(CommsWeb.Plugs.SpaEntryPoint)

  plug(Plug.Static,
    at: "/",
    from: :comms_web,
    gzip: false,
    only: CommsWeb.static_paths()
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])
  plug(CommsWeb.Plugs.Cors)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    length: 2_000_000,
    json_decoder: Phoenix.json_library()
  )

  plug(CommsWeb.Router)
end
