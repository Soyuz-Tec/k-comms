defmodule CommsWorkers.Release do
  @moduledoc false

  alias CommsCore.Release, as: CoreRelease
  alias CommsIntegrations.ObjectStorage

  def remap_restored_attachment_versions do
    {:ok, _started} = Application.ensure_all_started(:comms_integrations)

    CoreRelease.remap_restored_attachment_versions(&ObjectStorage.verify_restored_object/1)
  end
end
