defmodule CommsCore.Repo do
  use Ecto.Repo, otp_app: :comms_core, adapter: Ecto.Adapters.Postgres
end
