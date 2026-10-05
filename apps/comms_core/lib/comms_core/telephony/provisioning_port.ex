defmodule CommsCore.Telephony.ProvisioningPort do
  @moduledoc "Default-closed resolution of the configured SIP provisioning adapter."
  import Kernel, except: [inspect: 1]

  @disabled %{
    enabled: false,
    ready: false,
    reason: "provider_management_disabled",
    number_purchase: false,
    trunk_credentials_edit: false
  }

  def enabled?,
    do: Application.get_env(:comms_core, :telephony_provisioning_enabled, false) == true

  @spec status(String.t()) :: map()
  def status(tenant_id) do
    with true <- enabled?(), {:ok, module} <- adapter() do
      module.status(tenant_id)
      |> Map.take([:enabled, :ready, :reason, :number_purchase, :trunk_credentials_edit])
    else
      _ -> @disabled
    end
  end

  @spec inspect(CommsCore.Telephony.ProvisioningRequest.t()) :: {:ok, map()} | {:error, atom()}
  def inspect(request) do
    with true <- enabled?(), {:ok, module} <- adapter() do
      module.inspect(request)
    else
      _ -> {:error, :telephony_provisioning_disabled}
    end
  end

  @spec apply(CommsCore.Telephony.ProvisioningRequest.t()) :: {:ok, map()} | {:error, atom()}
  def apply(request) do
    with true <- enabled?(), {:ok, module} <- adapter() do
      module.apply(request)
    else
      _ -> {:error, :telephony_provisioning_disabled}
    end
  end

  defp adapter do
    with {:ok, module} <- Application.fetch_env(:comms_core, :telephony_provisioning_adapter),
         true <- is_atom(module) and Code.ensure_loaded?(module),
         true <-
           Enum.all?([status: 1, inspect: 1, apply: 1], fn {name, arity} ->
             function_exported?(module, name, arity)
           end) do
      {:ok, module}
    else
      _ -> {:error, :telephony_provider_unavailable}
    end
  end
end
