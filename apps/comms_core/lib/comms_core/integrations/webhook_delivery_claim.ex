defmodule CommsCore.Integrations.WebhookDeliveryClaim do
  @moduledoc """
  Capability returned to the webhook worker for one claimed delivery attempt.

  The claim deliberately omits tenant, endpoint, payload, and secret metadata. The
  owner reloads those values under lock before dispatch or recording a result.
  """

  @derive {Inspect, except: [:claim_token]}
  @enforce_keys [:id, :claim_generation, :claim_token]
  defstruct [:id, :claim_generation, :claim_token]
end
