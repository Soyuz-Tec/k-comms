defmodule CommsCore.SharedDocuments.Operation do
  @moduledoc false
  use CommsCore.Schema

  schema "shared_document_operations" do
    field(:tenant_id, Ecto.UUID)
    field(:conversation_id, Ecto.UUID)
    field(:document_id, Ecto.UUID)
    field(:actor_user_id, Ecto.UUID)
    field(:actor_device_id, Ecto.UUID)
    field(:client_operation_id, Ecto.UUID)
    field(:generation, :integer)
    field(:version, :integer)
    field(:kind, :string)
    field(:input, :map)
    field(:payload, :map)
    timestamps(updated_at: false)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :tenant_id,
      :conversation_id,
      :document_id,
      :actor_user_id,
      :actor_device_id,
      :client_operation_id,
      :generation,
      :version,
      :kind,
      :input,
      :payload
    ])
    |> validate_required([
      :tenant_id,
      :conversation_id,
      :document_id,
      :actor_user_id,
      :actor_device_id,
      :client_operation_id,
      :generation,
      :version,
      :kind,
      :input,
      :payload
    ])
    |> unique_constraint(:client_operation_id, name: :shared_document_operations_client_id_unique)
    |> unique_constraint(:version, name: :shared_document_operations_version_unique)
  end
end
