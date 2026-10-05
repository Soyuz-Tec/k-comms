defmodule CommsCore.Telephony.VoicemailObject do
  @moduledoc "Exact tenant-bound voicemail object; unversioned media is never playable."
  @enforce_keys [:tenant_id, :voicemail_id, :object_key]
  defstruct [
    :tenant_id,
    :voicemail_id,
    :object_key,
    :object_version_id,
    :object_etag,
    :checksum_sha256,
    :verified_checksum_sha256,
    :byte_size,
    content_type: "audio/wav"
  ]

  @type t :: %__MODULE__{tenant_id: String.t(), voicemail_id: String.t(), object_key: String.t()}
  def key(tenant_id, id), do: tenant_id <> "/voicemail/" <> id <> ".wav"

  def valid?(%__MODULE__{} = object) do
    match?({:ok, _}, Ecto.UUID.cast(object.tenant_id)) and
      match?({:ok, _}, Ecto.UUID.cast(object.voicemail_id)) and
      object.object_key == key(object.tenant_id, object.voicemail_id) and
      object.content_type == "audio/wav"
  end

  def valid?(_), do: false

  def verified?(%__MODULE__{} = object) do
    valid?(object) and is_binary(object.object_version_id) and
      object.object_version_id not in ["", "null"] and
      is_binary(object.object_etag) and object.object_etag != "" and
      is_integer(object.byte_size) and object.byte_size in 1..8_388_608 and
      is_binary(object.checksum_sha256) and
      Regex.match?(~r/^[a-f0-9]{64}$/, object.checksum_sha256) and
      object.verified_checksum_sha256 == object.checksum_sha256
  end

  def verified?(_), do: false
end
