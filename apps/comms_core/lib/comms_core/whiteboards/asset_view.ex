defmodule CommsCore.Whiteboards.AssetView do
  @moduledoc "Authorized durable image reference without storage identity."
  @enforce_keys [:id, :attachment_id, :source_message_id, :content_type, :byte_size]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: binary(),
          attachment_id: binary(),
          source_message_id: binary(),
          content_type: binary(),
          byte_size: pos_integer()
        }
end
