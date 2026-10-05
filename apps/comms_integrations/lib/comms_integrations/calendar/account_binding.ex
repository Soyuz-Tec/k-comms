defmodule CommsIntegrations.Calendar.AccountBinding do
  @moduledoc false
  alias CommsCore.AudioCalls.CalendarSync.ExternalIdentityReceipt
  alias CommsIntegrations.Calendar.{Config, Http}

  # Compare the current access token's provider-native OIDC subject before any
  # event effect or absence proof. A different account's 404 cannot clear data.
  # Names/emails returned by UserInfo are discarded inside this adapter.
  def verify(
        %Config{} = config,
        %ExternalIdentityReceipt{provider: provider, oidc_subject: expected},
        access_token,
        deadline,
        opts
      )
      when provider == config.provider and is_binary(expected) do
    with {:ok, %{status: 200, body: body}} <-
           Http.request(
             :get,
             Config.endpoints(config).userinfo,
             [{"authorization", "Bearer " <> access_token}, {"accept", "application/json"}],
             "",
             deadline,
             opts
           ),
         {:ok, %{"sub" => subject}} <- Http.json(body),
         true <- is_binary(subject) and byte_size(subject) == byte_size(expected),
         true <- :crypto.hash_equals(subject, expected) do
      :ok
    else
      _ -> {:error, :calendar_external_account_binding_failed}
    end
  end

  def verify(_, _, _, _, _), do: {:error, :calendar_external_account_binding_failed}
end
