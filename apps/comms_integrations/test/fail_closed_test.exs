defmodule CommsIntegrations.FailClosedTest do
  use ExUnit.Case, async: true
  test "outbound adapters deny by default" do
    assert {:error, _} = CommsIntegrations.Notifications.deliver(%{})
    assert {:error, _} = CommsIntegrations.ObjectStorage.sign_upload(%{})
    assert {:error, _} = CommsIntegrations.Webhooks.deliver(%{})
  end
end
