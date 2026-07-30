defmodule CommsCore.Attachments.Erasure do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Repo
  alias CommsCore.Attachments.{Attachment, AttachmentDeletionObject, AttachmentVariant}

  @doc """
  Returns the object-storage identities owned by an attachment erasure scope.

  Message-owned attachments are selected by `message_ids`. When
  `owner_user_id` is present, attachments directly owned by that user are
  included as the same tenant-scoped union. Deleted rows are never returned.
  Invalid scopes fail closed with an empty projection.
  """
  @spec erasure_objects(String.t(), [String.t()], String.t() | nil) ::
          [AttachmentDeletionObject.t()]
  def erasure_objects(tenant_id, message_ids, owner_user_id)
      when is_binary(tenant_id) and is_list(message_ids) and
             (is_binary(owner_user_id) or is_nil(owner_user_id)) do
    with {:ok, tenant_id} <- Ecto.UUID.cast(tenant_id),
         {:ok, message_ids} <- cast_uuid_list(message_ids),
         {:ok, owner_user_id} <- cast_optional_uuid(owner_user_id) do
      Attachment
      |> where([attachment], attachment.tenant_id == ^tenant_id)
      |> where([attachment], attachment.status != :deleted)
      |> erasure_scope_filter(message_ids, owner_user_id)
      |> order_by([attachment], asc: attachment.id)
      |> select([attachment], %{
        id: attachment.id,
        tenant_id: attachment.tenant_id,
        object_key: attachment.object_key,
        object_version_id: attachment.object_version_id
      })
      |> Repo.all()
      |> attach_variant_objects()
      |> Enum.map(&struct!(AttachmentDeletionObject, &1))
    else
      _ -> []
    end
  end

  def erasure_objects(_tenant_id, _message_ids, _owner_user_id), do: []

  @doc """
  Marks tenant-scoped attachments deleted as part of an existing erasure transaction.

  The persisted row is retained while user-visible file identity and the source
  checksum are scrubbed. Returns only the number of affected rows.
  """
  @spec mark_deleted_for_erasure(Ecto.UUID.t(), [Ecto.UUID.t()], DateTime.t()) ::
          {:ok, %{attachments_deleted: non_neg_integer()}}
          | {:error, :invalid_erasure_scope | :transaction_required}
  def mark_deleted_for_erasure(tenant_id, attachment_ids, %DateTime{} = timestamp)
      when is_binary(tenant_id) and is_list(attachment_ids) do
    if Repo.in_transaction?() do
      attachment_ids = Enum.uniq(attachment_ids)

      with :ok <- validate_erasure_scope(tenant_id, attachment_ids) do
        {attachments_deleted, _} =
          Repo.update_all(
            from(attachment in Attachment,
              where: attachment.tenant_id == ^tenant_id and attachment.id in ^attachment_ids
            ),
            set: [
              status: :deleted,
              file_name: "deleted",
              content_type: "application/octet-stream",
              checksum_sha256: nil,
              updated_at: timestamp
            ]
          )

        # Variants are derived from the erased content, so their descriptors go
        # with it. `erasure_objects` handed their keys to the deletion worker
        # before this runs, so removing the rows cannot strand an object.
        Repo.delete_all(
          from(variant in AttachmentVariant,
            where: variant.tenant_id == ^tenant_id and variant.attachment_id in ^attachment_ids
          )
        )

        {:ok, %{attachments_deleted: attachments_deleted}}
      end
    else
      {:error, :transaction_required}
    end
  end

  def mark_deleted_for_erasure(_tenant_id, _attachment_ids, _timestamp),
    do: {:error, :invalid_erasure_scope}

  defp attach_variant_objects([]), do: []

  defp attach_variant_objects(rows) do
    attachment_ids = Enum.map(rows, & &1.id)

    grouped =
      from(variant in AttachmentVariant,
        where: variant.attachment_id in ^attachment_ids,
        order_by: [asc: variant.kind],
        select: %{
          attachment_id: variant.attachment_id,
          object_key: variant.object_key,
          object_version_id: variant.object_version_id
        }
      )
      |> Repo.all()
      |> Enum.group_by(& &1.attachment_id)

    Enum.map(rows, fn row ->
      variants =
        grouped
        |> Map.get(row.id, [])
        |> Enum.map(&Map.take(&1, [:object_key, :object_version_id]))

      Map.put(row, :variants, variants)
    end)
  end

  defp validate_erasure_scope(tenant_id, ids) do
    if valid_uuid?(tenant_id) and Enum.all?(ids, &valid_uuid?/1),
      do: :ok,
      else: {:error, :invalid_erasure_scope}
  end

  defp erasure_scope_filter(query, [], nil), do: where(query, [attachment], false)

  defp erasure_scope_filter(query, message_ids, nil),
    do: where(query, [attachment], attachment.message_id in ^message_ids)

  defp erasure_scope_filter(query, [], owner_user_id),
    do: where(query, [attachment], attachment.owner_user_id == ^owner_user_id)

  defp erasure_scope_filter(query, message_ids, owner_user_id) do
    where(
      query,
      [attachment],
      attachment.message_id in ^message_ids or attachment.owner_user_id == ^owner_user_id
    )
  end

  defp cast_uuid_list(values) do
    values
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, ids} ->
      case Ecto.UUID.cast(value) do
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      :error -> :error
    end
  end

  defp cast_optional_uuid(nil), do: {:ok, nil}
  defp cast_optional_uuid(value), do: Ecto.UUID.cast(value)

  defp valid_uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
end
