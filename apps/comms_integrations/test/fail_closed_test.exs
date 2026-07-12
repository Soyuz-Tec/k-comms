defmodule CommsIntegrations.FailClosedTest do
  use ExUnit.Case, async: false

  test "outbound adapters deny by default" do
    adapter_keys = [:notification_adapter, :object_storage_adapter, :webhook_adapter]
    previous = Map.new(adapter_keys, &{&1, Application.get_env(:comms_integrations, &1)})

    on_exit(fn ->
      Enum.each(previous, fn {key, adapter} ->
        if is_nil(adapter) do
          Application.delete_env(:comms_integrations, key)
        else
          Application.put_env(:comms_integrations, key, adapter)
        end
      end)
    end)

    Enum.each(adapter_keys, &Application.delete_env(:comms_integrations, &1))

    assert {:error, _} = CommsIntegrations.Notifications.deliver(%{})
    assert {:error, _} = CommsIntegrations.ObjectStorage.sign_upload(%{})
    assert {:error, _} = CommsIntegrations.Webhooks.deliver(%{})
  end
end
