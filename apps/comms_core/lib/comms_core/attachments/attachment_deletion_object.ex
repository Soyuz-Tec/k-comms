defmodule CommsCore.Attachments.AttachmentDeletionObject do
  @moduledoc """
  Stable object-storage identity exposed for governed attachment erasure.

  The projection deliberately omits attachment persistence state and user or
  message ownership details.
  """

  @enforce_keys [:id, :tenant_id, :object_key, :object_version_id]
  defstruct [:id, :tenant_id, :object_key, :object_version_id]

  @type t :: %__MODULE__{
          id: String.t(),
          tenant_id: String.t(),
          object_key: String.t(),
          object_version_id: String.t() | nil
        }
end
