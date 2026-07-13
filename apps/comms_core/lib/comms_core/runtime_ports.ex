defmodule CommsCore.RuntimePorts do
  @moduledoc """
  Resolves adapter implementations supplied by the umbrella composition root.

  Core code owns the port names and contracts. Concrete worker and integration
  modules are configured outside `comms_core`, so the domain does not acquire a
  compile-time dependency on its delivery adapters.
  """

  @job_kinds [
    :attachment_scan,
    :deletion,
    :notification_delivery,
    :outbox_publication,
    :retention,
    :webhook_delivery
  ]

  @spec job_worker!(atom()) :: module()
  def job_worker!(kind) when kind in @job_kinds do
    :comms_core
    |> Application.fetch_env!(:job_workers)
    |> Keyword.fetch!(kind)
    |> validate_module!(:job_workers, kind)
  end

  @spec job_worker_name!(atom()) :: String.t()
  def job_worker_name!(kind), do: kind |> job_worker!() |> Module.split() |> Enum.join(".")

  @spec authorized_job_worker?(atom(), term()) :: boolean()
  def authorized_job_worker?(kind, caller), do: caller == job_worker!(kind)

  defp validate_module!(module, group, kind) when is_atom(module) do
    if module |> Atom.to_string() |> String.starts_with?("Elixir.") do
      module
    else
      invalid_module!(module, group, kind)
    end
  end

  defp validate_module!(value, group, kind), do: invalid_module!(value, group, kind)

  defp invalid_module!(value, group, kind) do
    raise ArgumentError,
          "invalid #{inspect(group)} runtime port #{inspect(kind)}: #{inspect(value)}"
  end
end
