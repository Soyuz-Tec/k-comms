defmodule CommsCore.Telephony.IvrMenuView do
  @moduledoc "Minimal reviewed menu projection; no tenant, call or provider bindings."
  @type destination :: %{
          required(String.t()) => String.t()
        }
  @type t :: %{
          id: String.t(),
          name: String.t(),
          prompt_media: String.t(),
          choices: %{String.t() => destination()},
          fallback: destination(),
          digit_timeout_seconds: pos_integer(),
          max_retries: non_neg_integer(),
          enabled: boolean(),
          version: pos_integer()
        }
end
