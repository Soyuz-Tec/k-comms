defmodule CommsIntegrations.TelephonyVoicemailS3IntegrationTest do
  use ExUnit.Case, async: false
  import CommsIntegrations.ObjectStorageTestSupport
  alias CommsCore.Telephony.{VoicemailObject, VoicemailStoragePort}
  alias CommsIntegrations.Telephony.VoicemailS3
  @moduletag :integration
  @moduletag :object_storage
  setup do
    values = %{
      s3: s3_integration_config(),
      object_storage_adapter: CommsIntegrations.ObjectStorage.S3,
      telephony_voicemail_storage_qualified: true
    }

    previous =
      Map.new(values, fn {key, _} -> {key, Application.fetch_env(:comms_integrations, key)} end)

    provider_previous = Application.fetch_env(:comms_core, :voicemail_storage_adapter)
    Enum.each(values, fn {key, value} -> Application.put_env(:comms_integrations, key, value) end)
    Application.put_env(:comms_core, :voicemail_storage_adapter, VoicemailS3)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:comms_integrations, key, value)
        {key, :error} -> Application.delete_env(:comms_integrations, key)
      end)

      case provider_previous do
        {:ok, value} -> Application.put_env(:comms_core, :voicemail_storage_adapter, value)
        :error -> Application.delete_env(:comms_core, :voicemail_storage_adapter)
      end
    end)

    :ok
  end

  test "real encrypted storage ingestion retries keep one version and playback remains pinned after replacement" do
    tenant = Ecto.UUID.generate()
    id = Ecto.UUID.generate()

    object = %VoicemailObject{
      tenant_id: tenant,
      voicemail_id: id,
      object_key: VoicemailObject.key(tenant, id)
    }

    bytes = "synthetic-provider-validated-PCM"
    assert {:ok, first} = VoicemailStoragePort.ingest(object, bytes)
    assert VoicemailObject.verified?(first)
    assert {:ok, repeated} = VoicemailStoragePort.ingest(object, bytes)
    assert repeated.object_version_id == first.object_version_id
    assert {:error, _} = VoicemailStoragePort.ingest(object, "different-provider-body")
    assert {:ok, signed} = VoicemailStoragePort.download(first)
    assert URI.decode_query(URI.parse(signed.url).query)["versionId"] == first.object_version_id
    assert signed.expires_in <= 120
    request = Finch.build(:get, signed.url)

    assert {:ok, %Finch.Response{status: 200, body: ^bytes}} =
             Finch.request(request, CommsIntegrations.Finch)

    replacement = "replacement"

    assert :ok =
             upload(
               %{first | byte_size: byte_size(replacement), checksum_sha256: sha256(replacement)},
               replacement
             )

    assert {:ok, %Finch.Response{status: 200, body: ^bytes}} =
             Finch.request(request, CommsIntegrations.Finch)

    Application.put_env(:comms_integrations, :telephony_voicemail_storage_qualified, false)
    assert :ok = VoicemailStoragePort.delete(first)

    assert {:ok, %{verified_empty?: true}} =
             CommsIntegrations.ObjectStorage.purge_object_versions(first)
  end

  test "storage qualification and exact tenant key are required before issuing playback" do
    Application.put_env(:comms_integrations, :telephony_voicemail_storage_qualified, false)
    refute VoicemailS3.ready?()

    object = %VoicemailObject{
      tenant_id: Ecto.UUID.generate(),
      voicemail_id: Ecto.UUID.generate(),
      object_key: "foreign/voice.wav"
    }

    assert {:error, :voicemail_storage_identity_invalid} = VoicemailStoragePort.download(object)
  end
end
