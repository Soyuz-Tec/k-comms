defmodule CommsObservability.MixProject do
  use Mix.Project

  def project do
    [
      app: :comms_observability,
      version: "0.2.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: [{:telemetry, "~> 1.3"}]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {CommsObservability.Application, []}]
  end
end
