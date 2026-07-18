defmodule CommsWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :comms_web

  socket("/socket", CommsWeb.UserSocket,
    websocket: [connect_info: [:peer_data, :x_headers]],
    longpoll: false
  )

  plug(CommsWeb.Plugs.SecurityHeaders)

  plug(Plug.Static,
    at: "/",
    from: :comms_web,
    gzip: false,
    only: CommsWeb.static_paths()
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])
  plug(CommsWeb.Plugs.TrustedProxy)
  plug(CommsWeb.Plugs.Cors)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    length: 2_000_000,
    json_decoder: Phoenix.json_library()
  )

  plug(CommsWeb.Router)
end
