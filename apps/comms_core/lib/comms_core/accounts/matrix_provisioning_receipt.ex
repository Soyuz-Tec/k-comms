defmodule CommsCore.Accounts.MatrixProvisioningReceipt do
  @moduledoc "Internal verified provider receipt. Refresh tokens remain server-custodied."
  @enforce_keys [:matrix_user_id]
  defstruct [
    :matrix_user_id,
    :matrix_device_id,
    :access_token,
    :refresh_token,
    :expires_in_ms,
    :revoked?
  ]

  @type t :: %__MODULE__{
          matrix_user_id: String.t(),
          matrix_device_id: String.t() | nil,
          access_token: String.t() | nil,
          refresh_token: String.t() | nil,
          expires_in_ms: pos_integer() | nil,
          revoked?: boolean() | nil
        }
  defimpl Inspect do
    import Inspect.Algebra

    def inspect(receipt, opts),
      do:
        concat([
          "#MatrixProvisioningReceipt<",
          to_doc(
            Map.take(Map.from_struct(receipt), [
              :matrix_user_id,
              :matrix_device_id,
              :expires_in_ms,
              :revoked?
            ]),
            opts
          ),
          ">"
        ])
  end
end
