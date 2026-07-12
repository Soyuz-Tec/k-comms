defmodule CommsCore.Attachments do
  import Ecto.Query

  alias CommsCore.{Authorization, Repo}
  alias CommsCore.Attachments.Attachment
  alias CommsCore.Messaging.Message

  @allowed_prefixes ["image/", "text/"]
  @allowed_exact ["application/pdf", "application/zip", "application/json"]
  @max_bytes 25_000_000

  def create_intent(attrs, subject) do
    content_type = value(attrs, :content_type) || "application/octet-stream"
    byte_size = integer(value(attrs, :byte_size))
    checksum = normalize_checksum(value(attrs, :checksum_sha256))

    with :ok <- validate_type(content_type),
         :ok <- validate_size(byte_size),
         :ok <- validate_checksum(checksum) do
      id = Ecto.UUID.generate()
      file_name = sanitize_file_name(value(attrs, :file_name) || "attachment")
      object_key = "#{value(subject, :tenant_id)}/#{id}/#{file_name}"

      %Attachment{id: id}
      |> Attachment.changeset(%{
        tenant_id: value(subject, :tenant_id),
        owner_user_id: value(subject, :user_id),
        object_key: object_key,
        file_name: file_name,
        content_type: content_type,
        byte_size: byte_size,
        checksum_sha256: checksum,
        status: :pending
      })
      |> Repo.insert()
    end
  end

  def mark_uploaded(id, checksum, subject) do
    checksum = normalize_checksum(checksum)

    with %Attachment{} = attachment <- owned_pending(id, subject),
         :ok <- validate_checksum(checksum),
         :ok <- checksum_matches(attachment, checksum) do
      attachment
      |> Attachment.changeset(%{
        checksum_sha256: checksum || attachment.checksum_sha256,
        status: :ready,
        uploaded_at: now()
      })
      |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  def get_authorized(id, subject) do
    with %Attachment{} = attachment <-
           Repo.get_by(Attachment, id: id, tenant_id: value(subject, :tenant_id)),
         :ok <- authorize_attachment(attachment, subject) do
      {:ok, attachment}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def list_for_message(message_id) do
    Attachment
    |> where([a], a.message_id == ^message_id and a.status == :ready)
    |> order_by([a], asc: a.inserted_at)
    |> Repo.all()
  end

  def attach_ready(ids, %Message{} = message, subject) when is_list(ids) do
    ids = Enum.uniq(ids)

    if ids == [] do
      :ok
    else
      query =
        from(a in Attachment,
          where:
            a.id in ^ids and a.tenant_id == ^message.tenant_id and
              a.owner_user_id == ^value(subject, :user_id) and a.status == :ready and
              is_nil(a.message_id)
        )

      {count, _} = Repo.update_all(query, set: [message_id: message.id, updated_at: now()])
      if count == length(ids), do: :ok, else: Repo.rollback(:invalid_attachments)
    end
  end

  defp owned_pending(id, subject) do
    Repo.get_by(Attachment,
      id: id,
      tenant_id: value(subject, :tenant_id),
      owner_user_id: value(subject, :user_id),
      status: :pending
    )
  end

  defp authorize_attachment(%Attachment{owner_user_id: owner_id} = attachment, subject) do
    if owner_id == value(subject, :user_id) do
      :ok
    else
      authorize_attached_message(attachment, subject)
    end
  end

  defp authorize_attached_message(%Attachment{message_id: message_id}, subject)
       when is_binary(message_id) do
    case Repo.get(Message, message_id) do
      %Message{} = message -> Authorization.authorize(:read_conversation, subject, message)
      nil -> {:error, :forbidden}
    end
  end

  defp authorize_attached_message(_, _), do: {:error, :forbidden}

  defp validate_type(type) do
    if type in @allowed_exact or Enum.any?(@allowed_prefixes, &String.starts_with?(type, &1)) do
      :ok
    else
      {:error, :unsupported_content_type}
    end
  end

  defp validate_size(size) when is_integer(size) and size > 0 and size <= @max_bytes, do: :ok
  defp validate_size(_), do: {:error, :invalid_attachment_size}

  defp validate_checksum(nil), do: :ok

  defp validate_checksum(checksum) when is_binary(checksum) do
    if Regex.match?(~r/^[a-f0-9]{64}$/, checksum),
      do: :ok,
      else: {:error, :invalid_attachment_checksum}
  end

  defp validate_checksum(_), do: {:error, :invalid_attachment_checksum}

  defp checksum_matches(%Attachment{checksum_sha256: nil}, _checksum), do: :ok
  defp checksum_matches(%Attachment{checksum_sha256: checksum}, checksum), do: :ok
  defp checksum_matches(_attachment, _checksum), do: {:error, :attachment_checksum_mismatch}

  defp normalize_checksum(nil), do: nil

  defp normalize_checksum(checksum) when is_binary(checksum),
    do: checksum |> String.trim() |> String.downcase()

  defp normalize_checksum(_), do: :invalid

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
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
