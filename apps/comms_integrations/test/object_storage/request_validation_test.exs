defmodule CommsIntegrations.ObjectStorage.RequestValidationTest do
  use ExUnit.Case, async: false

  import CommsIntegrations.ObjectStorageTestSupport

  @moduletag :unit
  @moduletag :object_storage

  test "object deletion rejects cross-tenant and unsafe object keys before reaching an adapter" do
    previous = Application.get_env(:comms_integrations, :object_storage_adapter)

    Application.put_env(
      :comms_integrations,
      :object_storage_adapter,
      CommsIntegrations.ObjectStorage.Memory
    )

    on_exit(fn -> restore_env(:object_storage_adapter, previous) end)

    assert {:error, :object_tenant_mismatch} =
             CommsIntegrations.ObjectStorage.delete_object(%{
               tenant_id: "tenant-a",
               object_key: "tenant-b/file.txt"
             })

    for key <- ["tenant-a/../file.txt", "tenant-a/path\\file.txt", "tenant-a/path//file.txt"] do
      assert {:error, :invalid_object_key} =
               CommsIntegrations.ObjectStorage.delete_object(%{
                 tenant_id: "tenant-a",
                 object_key: key
               })

      assert {:error, :invalid_object_key} =
               CommsIntegrations.ObjectStorage.purge_object_versions(%{
                 tenant_id: "tenant-a",
                 object_key: key
               })
    end

    assert {:error, :object_tenant_mismatch} =
             CommsIntegrations.ObjectStorage.purge_object_versions(%{
               tenant_id: "tenant-a",
               object_key: "tenant-b/file.txt"
             })
  end
end
