defmodule CommsIntegrations.WebhookSecurityTest do
  use ExUnit.Case, async: false

  test "HTTP adapter rejects non-HTTPS and unapproved hosts before making a request" do
    previous = Application.get_env(:comms_integrations, :webhook_allowed_hosts)
    Application.put_env(:comms_integrations, :webhook_allowed_hosts, ["hooks.example.test"])

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:comms_integrations, :webhook_allowed_hosts)
      else
        Application.put_env(:comms_integrations, :webhook_allowed_hosts, previous)
      end
    end)

    assert {:error, :webhook_destination_not_allowed} =
             CommsIntegrations.Webhooks.Http.deliver(%{
               "url" => "http://hooks.example.test/events",
               "secret" => "test-secret",
               "body" => %{}
             })

    assert {:error, :webhook_destination_not_allowed} =
             CommsIntegrations.Webhooks.Http.deliver(%{
               "url" => "https://127.0.0.1/events",
               "secret" => "test-secret",
               "body" => %{}
             })
  end
end
