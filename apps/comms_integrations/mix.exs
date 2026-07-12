defmodule CommsIntegrations.MixProject do
  use Mix.Project

  def project do
    [
      app: :comms_integrations,
      version: "0.3.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {CommsIntegrations.Application, []}]
  end

  defp deps do
    [
      {:comms_observability, in_umbrella: true},
      {:finch, "~> 0.20"},
      {:mint, "~> 1.9"},
      {:jason, "~> 1.4"}
    ]
  end
end
