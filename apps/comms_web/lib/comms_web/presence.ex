defmodule CommsWeb.Presence do
  use Phoenix.Presence, otp_app: :comms_web, pubsub_server: CommsWeb.PubSub
end
