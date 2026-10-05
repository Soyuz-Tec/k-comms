defmodule CommsCore.SharedDocuments.Document do
  @moduledoc false
  use CommsCore.Schema

  schema "shared_documents" do
    field(:tenant_id, Ecto.UUID)
    field(:conversation_id, Ecto.UUID)
    field(:created_by_user_id, Ecto.UUID)
    field(:created_by_device_id, Ecto.UUID)
    field(:client_document_id, Ecto.UUID)
    field(:title, :string)
    field(:content, :string, default: "")
    field(:atoms, {:array, :map}, default: [])
    field(:author_user_ids, {:array, Ecto.UUID}, default: [])
    field(:lineage_verified, :boolean, default: true)
    field(:generation, :integer, default: 1)
    field(:version, :integer, default: 0)
    field(:retained_operation_bytes, :integer, default: 0)
    field(:erased_at, :utc_datetime_usec)
    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :tenant_id,
      :conversation_id,
      :created_by_user_id,
      :created_by_device_id,
      :client_document_id,
      :title,
      :content,
      :atoms,
      :author_user_ids,
      :lineage_verified,
      :generation,
      :version,
      :retained_operation_bytes,
      :erased_at
    ])
    |> validate_required([
      :tenant_id,
      :conversation_id,
      :client_document_id,
      :title,
      :generation,
      :version,
      :lineage_verified
    ])
    |> validate_length(:title, min: 1, max: 160)
    |> unique_constraint(:client_document_id, name: :shared_documents_client_id_unique)
  end
end
