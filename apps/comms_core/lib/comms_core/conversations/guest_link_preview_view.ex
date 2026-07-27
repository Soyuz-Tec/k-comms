defmodule CommsCore.Conversations.GuestLinkPreviewView do
  @moduledoc """
  Minimal public projection disclosed before a guest link is redeemed.

  This deliberately excludes tenant and conversation identifiers, internal
  lifecycle state, usage counters, capabilities, versions, and activity
  timestamps.
  """

  @enforce_keys [
    :room_title,
    :expires_at,
    :conversion_enabled,
    :email_hint
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          room_title: String.t(),
          expires_at: DateTime.t(),
          conversion_enabled: boolean(),
          email_hint: String.t() | nil
        }
end
