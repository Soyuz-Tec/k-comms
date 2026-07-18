defmodule CommsCore.Administration.ConversationContentPolicy do
  @moduledoc """
  Minimal tenant policy projection used by ConversationContent.

  Tenant settings persistence and unrelated tenant capabilities remain private
  to TenantAdministration.
  """

  @enforce_keys [:tenant_id, :message_edit_window_seconds, :max_attachment_bytes]
  defstruct [:tenant_id, :message_edit_window_seconds, :max_attachment_bytes]

  @type t :: %__MODULE__{
          tenant_id: Ecto.UUID.t(),
          message_edit_window_seconds: non_neg_integer(),
          max_attachment_bytes: pos_integer()
        }
end
