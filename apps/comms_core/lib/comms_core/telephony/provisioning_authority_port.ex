defmodule CommsCore.Telephony.ProvisioningAuthorityPort do
  @moduledoc "Exact provider identity and current-owner IO authorization for the configured Phone adapter."

  @spec authorized_adapter?(module()) :: boolean()
  def authorized_adapter?(caller) do
    with true <- Application.get_env(:comms_core, :telephony_provisioning_enabled, false) == true,
         {:ok, ^caller} <- Application.fetch_env(:comms_core, :telephony_provisioning_adapter),
         true <- is_atom(caller) and Code.ensure_loaded?(caller) do
      Enum.all?([status: 1, inspect: 1, apply: 1], fn {name, arity} ->
        function_exported?(caller, name, arity)
      end)
    else
      _ -> false
    end
  end

  @spec authorize_io(CommsCore.Telephony.ProvisioningRequest.t(), :read | :effect, module()) ::
          :ok | {:error, atom()}
  defdelegate authorize_io(request, mode, caller),
    to: CommsCore.Telephony,
    as: :authorize_phone_provisioning_io
end
