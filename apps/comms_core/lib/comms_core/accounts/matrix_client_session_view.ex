defmodule CommsCore.Accounts.MatrixClientSessionView do
  @moduledoc "Short-lived Matrix client authentication, delivered only to the exact current retained K session. Never contains private encryption or recovery keys."
  @enforce_keys [
    :homeserver_url,
    :matrix_user_id,
    :matrix_device_id,
    :access_token,
    :expires_at,
    :k_session_id,
    :control_matrix_user_id
  ]
  defstruct [
    :homeserver_url,
    :matrix_user_id,
    :matrix_device_id,
    :access_token,
    :expires_at,
    :k_session_id,
    :control_matrix_user_id
  ]

  @type t :: %__MODULE__{
          homeserver_url: String.t(),
          matrix_user_id: String.t(),
          matrix_device_id: String.t(),
          access_token: String.t(),
          expires_at: DateTime.t(),
          k_session_id: String.t(),
          control_matrix_user_id: String.t()
        }
  # Authentication tokens must not appear in logs, crash reports or default Inspect.
  defimpl Inspect do
    import Inspect.Algebra

    def inspect(view, opts),
      do:
        concat([
          "#MatrixClientSessionView<",
          to_doc(Map.drop(Map.from_struct(view), [:access_token]), opts),
          ">"
        ])
  end
end
