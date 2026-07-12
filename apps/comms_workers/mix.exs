defmodule CommsWorkers.MixProject do
  use Mix.Project
  def project, do: [app: :comms_workers, version: "0.1.0", build_path: "../../_build", config_path: "../../config/config.exs", deps_path: "../../deps", lockfile: "../../mix.lock", elixir: "~> 1.20", start_permanent: Mix.env() == :prod, deps: [{:comms_core, in_umbrella: true}, {:comms_integrations, in_umbrella: true}, {:oban, "~> 2.23"}]]
  def application, do: [extra_applications: [:logger]]
end
