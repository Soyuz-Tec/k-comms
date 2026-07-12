defmodule CommsTestSupport.MixProject do
  use Mix.Project
  def project, do: [app: :comms_test_support, version: "0.1.0", build_path: "../../_build", config_path: "../../config/config.exs", deps_path: "../../deps", lockfile: "../../mix.lock", elixir: "~> 1.20", deps: [{:comms_core, in_umbrella: true}]]
  def application, do: [extra_applications: [:logger]]
end
