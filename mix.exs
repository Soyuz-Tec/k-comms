defmodule KComms.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      releases: releases()
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run apps/comms_core/priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      check: ["format --check-formatted", "compile --warnings-as-errors", "test"]
    ]
  end

  defp releases do
    [
      k_comms: [
        include_executables_for: [:unix],
        applications: [
          comms_observability: :permanent,
          comms_integrations: :permanent,
          comms_core: :permanent,
          comms_workers: :permanent,
          comms_web: :permanent
        ]
      ]
    ]
  end
end
