defmodule CommsCore.Conversations.Federation.View do
  @moduledoc "Exact presentation with no provider credential, private mapping, payload or session identifiers."
  @enforce_keys [
    :id,
    :conversation_id,
    :domain,
    :residency,
    :status,
    :version,
    :consent,
    :remote_cleanup_state
  ]
  defstruct [
    :id,
    :conversation_id,
    :domain,
    :residency,
    :status,
    :version,
    :consent,
    :remote_cleanup_state
  ]

  @type t :: %__MODULE__{}
end
