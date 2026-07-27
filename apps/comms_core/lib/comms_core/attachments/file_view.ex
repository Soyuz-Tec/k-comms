defmodule CommsCore.Attachments.FileView do
  @moduledoc """
  Persistence-free file projection for the member Files surface.

  Storage identity and checksums intentionally remain inside the
  ConversationContent boundary. `duration`-style or workflow-derived fields
  are likewise absent: this projection contains only the persisted source,
  safety state, and whether the existing download policy currently permits a
  download.
  """

  @enforce_keys [
    :id,
    :conversation_id,
    :message_id,
    :conversation_sequence,
    :owner_user_id,
    :file_name,
    :content_type,
    :byte_size,
    :status,
    :scan_status,
    :safety_state,
    :downloadable,
    :shared_at,
    :inserted_at,
    :updated_at
  ]
  defstruct [
    :id,
    :conversation_id,
    :message_id,
    :conversation_sequence,
    :owner_user_id,
    :file_name,
    :content_type,
    :byte_size,
    :status,
    :scan_status,
    :safety_state,
    :downloadable,
    :uploaded_at,
    :shared_at,
    :inserted_at,
    :updated_at
  ]

  @type safety_state :: :available | :processing | :blocked | :failed | :unavailable

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          conversation_id: Ecto.UUID.t(),
          message_id: Ecto.UUID.t(),
          conversation_sequence: pos_integer(),
          owner_user_id: Ecto.UUID.t(),
          file_name: String.t(),
          content_type: String.t(),
          byte_size: pos_integer(),
          status: atom(),
          scan_status: atom(),
          safety_state: safety_state(),
          downloadable: boolean(),
          uploaded_at: DateTime.t() | nil,
          shared_at: DateTime.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
