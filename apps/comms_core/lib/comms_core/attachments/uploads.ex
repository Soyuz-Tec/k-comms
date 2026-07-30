defmodule CommsCore.Attachments.Uploads do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Administration, Conversations, Repo}
  alias CommsCore.Attachments.{Attachment, AttachmentVariant, AttachmentView, Projector, Safety}

  @allowed_prefixes ["image/", "text/"]
  @allowed_exact ["application/pdf", "application/zip", "application/json"]
  @default_max_bytes 26_214_400
  @schema_max_bytes 1_073_741_824
  @max_upload_ttl_seconds 3_600

  def create_intent(attrs, subject) do
    content_type = value(attrs, :content_type) || "application/octet-stream"
    byte_size = integer(value(attrs, :byte_size))
    checksum = normalize_checksum(value(attrs, :checksum_sha256))

    with {:ok, max_bytes} <- attachment_limit(subject),
         :ok <- validate_type(content_type),
         :ok <- validate_size(byte_size, max_bytes),
         :ok <- validate_checksum(checksum),
         {:ok, thumbnail} <- thumbnail_intent(attrs, content_type) do
      id = Ecto.UUID.generate()
      file_name = sanitize_file_name(value(attrs, :file_name) || "attachment")
      tenant_id = value(subject, :tenant_id)
      object_key = "#{tenant_id}/#{id}/#{file_name}"

      Repo.transaction(fn ->
        attachment =
          %Attachment{id: id}
          |> Attachment.changeset(%{
            tenant_id: tenant_id,
            owner_user_id: value(subject, :user_id),
            object_key: object_key,
            file_name: file_name,
            content_type: content_type,
            byte_size: byte_size,
            checksum_sha256: checksum,
            status: :pending
          })
          |> Repo.insert()
          |> case do
            {:ok, inserted} -> inserted
            {:error, changeset} -> Repo.rollback(changeset)
          end

        # The variant is inserted in the same transaction as the attachment, so
        # an attachment can never exist alongside a half-declared variant.
        case insert_variant(attachment, :thumbnail, thumbnail) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        Repo.preload(attachment, :variants)
      end)
      |> unwrap_transaction()
      |> project_result()
    end
  end

  defp insert_variant(_attachment, _kind, nil), do: :ok

  defp insert_variant(attachment, kind, declared) do
    %AttachmentVariant{}
    |> AttachmentVariant.changeset(%{
      tenant_id: attachment.tenant_id,
      attachment_id: attachment.id,
      kind: kind,
      # A fixed leaf keeps the variant inside the attachment-unique prefix that
      # cleanup already reasons about, and keeps the user-supplied file name out
      # of a second key.
      object_key: "#{attachment.tenant_id}/#{attachment.id}/#{kind}",
      content_type: declared.content_type,
      byte_size: declared.byte_size,
      checksum_sha256: declared.checksum_sha256
    })
    |> Repo.insert()
    |> case do
      {:ok, _variant} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Records a verified variant object against an attachment.

  A variant is an enhancement, so this never gates the attachment: a caller that
  cannot verify one simply leaves it unrecorded and the attachment completes
  without it.
  """
  @spec record_variant(String.t(), atom(), map(), map()) ::
          {:ok, AttachmentView.t()} | {:error, term()}
  def record_variant(id, kind, identity, subject)
      when is_binary(id) and is_atom(kind) and is_map(identity) do
    version = value(identity, :object_version_id)

    if is_binary(version) and version not in ["", "null"] do
      Repo.transaction(fn ->
        attachment = owned_for_update(id, subject) || Repo.rollback(:not_found)

        variant =
          Repo.one(
            from(variant in AttachmentVariant,
              where:
                variant.attachment_id == ^attachment.id and
                  variant.tenant_id == ^attachment.tenant_id and
                  variant.kind == ^kind,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:variant_not_declared)

        variant
        |> AttachmentVariant.changeset(%{
          object_version_id: version,
          uploaded_at: now()
        })
        |> Repo.update!()

        Repo.preload(attachment, :variants, force: true)
      end)
      |> unwrap_transaction()
      |> project_result()
    else
      {:error, :variant_version_unavailable}
    end
  end

  def record_variant(_id, _kind, _identity, _subject), do: {:error, :variant_version_unavailable}

  @doc """
  Returns a verified variant of the requested kind, when one may be served.

  A variant never precedes its parent's scan verdict: it is derived from content
  the scanner has not yet cleared, so it follows exactly the same gate as the
  download it stands in for.
  """
  def servable_variant(attachment, kind) do
    if Safety.downloadable?(attachment) do
      attachment
      |> variants()
      |> Enum.find(fn variant ->
        variant_kind(variant) == kind and is_binary(value(variant, :object_version_id))
      end)
    end
  end

  defp variants(attachment) do
    case value(attachment, :variants) do
      variants when is_list(variants) -> variants
      _ -> []
    end
  end

  defp variant_kind(variant) do
    case value(variant, :kind) do
      kind when is_atom(kind) -> kind
      kind when is_binary(kind) -> String.to_existing_atom(kind)
      _ -> nil
    end
  end

  defp thumbnail_intent(attrs, content_type) do
    declared = value(attrs, :thumbnail)

    cond do
      is_nil(declared) ->
        {:ok, nil}

      not is_map(declared) ->
        {:error, :invalid_thumbnail}

      # A thumbnail stands in for a preview of the object itself, so it is only
      # meaningful for content the client could have rendered.
      not String.starts_with?(content_type, "image/") ->
        {:error, :thumbnail_not_supported_for_content_type}

      true ->
        thumbnail_content_type = value(declared, :content_type)
        thumbnail_byte_size = integer(value(declared, :byte_size))
        thumbnail_checksum = normalize_checksum(value(declared, :checksum_sha256))

        cond do
          thumbnail_content_type not in AttachmentVariant.content_types() ->
            {:error, :unsupported_thumbnail_content_type}

          not (is_integer(thumbnail_byte_size) and thumbnail_byte_size > 0 and
                   thumbnail_byte_size <= AttachmentVariant.max_bytes()) ->
            {:error, :invalid_thumbnail_size}

          not (is_binary(thumbnail_checksum) and
                   Regex.match?(~r/^[a-f0-9]{64}$/, thumbnail_checksum)) ->
            {:error, :invalid_thumbnail_checksum}

          true ->
            {:ok,
             %{
               content_type: thumbnail_content_type,
               byte_size: thumbnail_byte_size,
               checksum_sha256: thumbnail_checksum
             }}
        end
    end
  end

  @doc """
  Persists the exact expiry of the upload authorization before it is returned.

  Abandonment cleanup is never allowed to complete before this deadline plus
  the configured settling grace. The bounded deadline is supplied by the
  object-storage signer that generated the authorization.
  """
  @spec record_upload_authorization(String.t(), DateTime.t(), map()) ::
          {:ok, AttachmentView.t()}
          | {:error, :not_found | :attachment_not_pending | :invalid_upload_expiry | term()}
  def record_upload_authorization(id, %DateTime{} = expires_at, subject)
      when is_binary(id) and is_map(subject) do
    current = now()
    expires_at = DateTime.truncate(expires_at, :microsecond)
    ttl_seconds = DateTime.diff(expires_at, current, :second)

    if ttl_seconds in 1..@max_upload_ttl_seconds do
      Repo.transaction(fn ->
        attachment = owned_for_update(id, subject) || Repo.rollback(:not_found)

        if attachment.status != :pending or is_binary(attachment.message_id) do
          Repo.rollback(:attachment_not_pending)
        end

        attachment
        |> Attachment.changeset(%{upload_expires_at: expires_at})
        |> Repo.update!()
      end)
      |> unwrap_transaction()
      |> project_result()
    else
      {:error, :invalid_upload_expiry}
    end
  end

  def record_upload_authorization(_id, _expires_at, _subject),
    do: {:error, :invalid_upload_expiry}

  def mark_uploaded(id, checksum, identity, subject) do
    checksum = normalize_checksum(checksum)

    with :ok <- validate_checksum(checksum),
         {:ok, identity} <- validate_identity(identity, checksum) do
      Repo.transaction(fn ->
        attachment = owned_for_update(id, subject) || Repo.rollback(:not_found)

        case checksum_matches(attachment, checksum) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        attachment =
          cond do
            attachment.status == :pending ->
              attachment
              |> Attachment.changeset(%{
                checksum_sha256: checksum,
                object_version_id: identity.object_version_id,
                object_etag: identity.object_etag,
                verified_checksum_sha256: identity.verified_checksum_sha256,
                status: :uploaded,
                scan_status: :pending,
                scan_verdict: nil,
                scan_error_code: nil,
                uploaded_at: now()
              })
              |> Repo.update!()

            attachment.status in [:uploaded, :ready] ->
              attachment

            true ->
              Repo.rollback(:attachment_not_pending)
          end

        case maybe_enqueue_scan(attachment) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        attachment
      end)
      |> unwrap_transaction()
      |> project_result()
    end
  end

  def get_authorized(id, subject) do
    with %Attachment{} = attachment <-
           Repo.get_by(Attachment, id: id, tenant_id: value(subject, :tenant_id)),
         :ok <- authorize_attachment(attachment, subject) do
      {:ok, Projector.attachment(attachment)}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp owned_for_update(id, subject) do
    Repo.one(
      from(attachment in Attachment,
        where:
          attachment.id == ^id and attachment.tenant_id == ^value(subject, :tenant_id) and
            attachment.owner_user_id == ^value(subject, :user_id),
        lock: "FOR UPDATE"
      )
    )
  end

  defp authorize_attachment(%Attachment{message_id: message_id} = attachment, subject)
       when is_binary(message_id),
       do: authorize_attached_message(attachment, subject)

  defp authorize_attachment(%Attachment{owner_user_id: owner_id}, subject) do
    if owner_id == value(subject, :user_id), do: :ok, else: {:error, :forbidden}
  end

  defp authorize_attached_message(%Attachment{message_id: message_id}, subject)
       when is_binary(message_id) do
    conversation_id =
      Repo.one(
        from(message in "messages",
          where:
            message.id == type(^message_id, :binary_id) and
              message.tenant_id == type(^value(subject, :tenant_id), :binary_id),
          select: message.conversation_id
        )
      )

    if is_binary(conversation_id),
      do: Conversations.authorize_read(conversation_id, subject),
      else: {:error, :forbidden}
  end

  defp validate_type(type) do
    if type in @allowed_exact or Enum.any?(@allowed_prefixes, &String.starts_with?(type, &1)) do
      :ok
    else
      {:error, :unsupported_content_type}
    end
  end

  defp validate_size(size, max_bytes)
       when is_integer(size) and is_integer(max_bytes) and size > 0 and size <= max_bytes,
       do: :ok

  defp validate_size(_, _), do: {:error, :invalid_attachment_size}

  defp validate_checksum(nil), do: {:error, :attachment_checksum_required}

  defp validate_checksum(checksum) when is_binary(checksum) do
    if Regex.match?(~r/^[a-f0-9]{64}$/, checksum),
      do: :ok,
      else: {:error, :invalid_attachment_checksum}
  end

  defp validate_checksum(_), do: {:error, :invalid_attachment_checksum}

  defp checksum_matches(%Attachment{checksum_sha256: checksum}, checksum), do: :ok
  defp checksum_matches(_attachment, _checksum), do: {:error, :attachment_checksum_mismatch}

  defp maybe_enqueue_scan(%Attachment{scan_status: status}) when status in [:clean, :blocked],
    do: :ok

  defp maybe_enqueue_scan(attachment), do: Safety.enqueue_scan(attachment)

  defp normalize_checksum(nil), do: nil

  defp normalize_checksum(checksum) when is_binary(checksum),
    do: checksum |> String.trim() |> String.downcase()

  defp normalize_checksum(_), do: :invalid

  defp validate_identity(identity, checksum) when is_map(identity) do
    version = value(identity, :object_version_id)
    etag = value(identity, :object_etag)
    verified_checksum = normalize_checksum(value(identity, :verified_checksum_sha256))

    if is_binary(version) and version not in ["", "null"] and is_binary(etag) and etag != "" and
         verified_checksum == checksum do
      {:ok,
       %{
         object_version_id: String.slice(version, 0, 1_024),
         object_etag: String.slice(etag, 0, 255),
         verified_checksum_sha256: verified_checksum
       }}
    else
      {:error, :object_identity_invalid}
    end
  end

  defp validate_identity(_, _), do: {:error, :object_identity_invalid}

  defp attachment_limit(subject) do
    case Administration.conversation_content_policy(subject) do
      {:ok, %Administration.ConversationContentPolicy{max_attachment_bytes: limit}}
      when is_integer(limit) and limit > 0 and limit <= @schema_max_bytes ->
        {:ok, limit}

      {:ok, _policy} ->
        {:ok, @default_max_bytes}

      {:error, _reason} = error ->
        error
    end
  end

  defp sanitize_file_name(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]/u, "_")
    |> String.slice(0, 255)
  end

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp integer(_), do: nil

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp project_result({:ok, %Attachment{} = attachment}),
    do: {:ok, Projector.attachment(attachment)}

  defp project_result({:error, reason}), do: {:error, reason}

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
