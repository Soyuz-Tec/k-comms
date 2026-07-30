defmodule KComms.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.3.0",
      start_permanent: Mix.env() == :prod,
      test_coverage: [
        summary: [threshold: 0],
        ignore_modules: [
          ~r/^Inspect\./,
          ~r/^CommsTestSupport(?:\.|$)/,
          ~r/^CommsCore\.(?:DataCase|.*Fixtures|.*TestSupport)$/,
          ~r/^CommsIntegrations\..*Test(?:Options|Support)(?:\.|$)/,
          ~r/^CommsWeb\..*(?:Case|TestSupport)(?:\.|$)/
        ]
      ],
      aliases: aliases(),
      releases: releases()
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": [
        "ecto.create",
        "ecto.migrate",
        "run apps/comms_core/priv/repo/seeds.exs"
      ],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "test"
      ],
      "test.unit": ["test --only unit --warnings-as-errors"],
      "test.integration": ["test --only integration --warnings-as-errors"],
      "test.concurrency": ["test --only concurrency --warnings-as-errors --trace"]
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
