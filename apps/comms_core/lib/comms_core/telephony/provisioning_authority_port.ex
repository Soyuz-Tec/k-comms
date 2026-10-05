defmodule CommsCore.Telephony.ProvisioningAuthorityPort do
  @moduledoc "Exact provider identity and current-owner IO authorization for the configured Phone adapter."

  @spec authorize_io(CommsCore.Telephony.ProvisioningRequest.t(), :read | :effect, module()) ::
          :ok | {:error, atom()}
  defdelegate authorize_io(request, mode, caller),
    to: CommsCore.Telephony,
    as: :authorize_phone_provisioning_io
end
