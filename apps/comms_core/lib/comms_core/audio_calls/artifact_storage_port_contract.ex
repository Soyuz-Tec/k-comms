defmodule CommsCore.AudioCalls.ArtifactStoragePort.Contract do
  @moduledoc "Calls-owned technical contract for approved artifact storage."
  alias CommsCore.AudioCalls.ArtifactStorageObject

  @type descriptor :: %{
          required(:url) => binary(),
          required(:approved_origin) => binary(),
          optional(atom()) =>
            binary() | integer() | boolean() | DateTime.t() | %{optional(binary()) => binary()}
        }
  @callback verify(ArtifactStorageObject.t()) ::
              {:ok, ArtifactStorageObject.t()} | {:error, atom()}
  @callback download(ArtifactStorageObject.t()) :: {:ok, descriptor()} | {:error, atom()}
  @callback delete(ArtifactStorageObject.t()) :: :ok | {:error, atom()}
end
