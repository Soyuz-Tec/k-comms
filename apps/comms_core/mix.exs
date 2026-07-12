defmodule CommsCore.MixProject do
  use Mix.Project

  def project do
    [app: :comms_core, version: "0.1.0", build_path: "../../_build", config_path: "../../config/config.exs", deps_path: "../../deps", lockfile: "../../mix.lock", elixir: "~> 1.20", start_permanent: Mix.env() == :prod, deps: deps()]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {CommsCore.Application, []}]
  end

  defp deps do
    [{:ecto_sql, "~> 3.13"}, {:postgrex, ">= 0.0.0"}, {:oban, "~> 2.23"}, {:jason, "~> 1.4"}]
  end
end
