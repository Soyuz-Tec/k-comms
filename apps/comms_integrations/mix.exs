defmodule CommsIntegrations.MixProject do
  use Mix.Project
  def project, do: [app: :comms_integrations, version: "0.1.0", build_path: "../../_build", config_path: "../../config/config.exs", deps_path: "../../deps", lockfile: "../../mix.lock", elixir: "~> 1.20", start_permanent: Mix.env() == :prod, deps: [{:comms_observability, in_umbrella: true}, {:finch, "~> 0.20"}]]
  def application, do: [extra_applications: [:logger], mod: {CommsIntegrations.Application, []}]
end
