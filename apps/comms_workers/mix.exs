defmodule CommsWorkers.MixProject do
  use Mix.Project

  def project do
    [
      app: :comms_workers,
      version: "0.2.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:comms_core, in_umbrella: true},
      {:comms_integrations, in_umbrella: true},
      {:oban, "~> 2.23"}
    ]
  end
end
