defmodule CommsWeb.MixProject do
  use Mix.Project
  def project do
    [app: :comms_web, version: "0.1.0", build_path: "../../_build", config_path: "../../config/config.exs", deps_path: "../../deps", lockfile: "../../mix.lock", elixir: "~> 1.20", start_permanent: Mix.env() == :prod, elixirc_paths: elixirc_paths(Mix.env()), deps: deps()]
  end
  def application, do: [extra_applications: [:logger, :runtime_tools], mod: {CommsWeb.Application, []}]
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
  defp deps do
    [{:comms_core, in_umbrella: true}, {:comms_observability, in_umbrella: true}, {:phoenix, "~> 1.8.1"}, {:phoenix_ecto, "~> 4.7"}, {:bandit, "~> 1.8"}, {:jason, "~> 1.4"}]
  end
end
