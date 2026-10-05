defmodule CommsCore.Accounts.MatrixProvisioningCommand do
  @moduledoc "IdentityAccess-owned internal authentication command. Its password is a provider authentication secret, never a message key."
  @enforce_keys [:tenant_id, :user_id, :matrix_user_id, :issuer, :password]
  defstruct [
    :tenant_id,
    :user_id,
    :matrix_user_id,
    :issuer,
    :password,
    :matrix_device_id,
    :refresh_token,
    :access_token,
    :public_signing_keys,
    :deadline
  ]

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          user_id: String.t(),
          matrix_user_id: String.t(),
          issuer: String.t(),
          password: String.t(),
          matrix_device_id: String.t() | nil,
          refresh_token: String.t() | nil,
          access_token: String.t() | nil,
          public_signing_keys: map() | nil,
          deadline: integer()
        }
  defimpl Inspect do
    import Inspect.Algebra

    def inspect(command, opts),
      do:
        concat([
          "#MatrixProvisioningCommand<",
          to_doc(
            Map.take(Map.from_struct(command), [
              :tenant_id,
              :user_id,
              :matrix_user_id,
              :issuer,
              :matrix_device_id
            ]),
            opts
          ),
          ">"
        ])
  end
end
