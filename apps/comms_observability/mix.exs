defmodule CommsObservability.MixProject do
  use Mix.Project
  def project, do: [app: :comms_observability, version: "0.1.0", build_path: "../../_build", config_path: "../../config/config.exs", deps_path: "../../deps", lockfile: "../../mix.lock", elixir: "~> 1.20", start_permanent: Mix.env() == :prod, deps: [{:telemetry, "~> 1.3"}]]
  def application, do: [extra_applications: [:logger]]
end
