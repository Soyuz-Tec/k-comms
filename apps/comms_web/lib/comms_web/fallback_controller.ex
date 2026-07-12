defmodule CommsWeb.FallbackController do
  use Phoenix.Controller, formats: [:json]

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    details =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Enum.reduce(opts, message, fn {key, value}, text ->
          String.replace(text, "%{#{key}}", to_string(value))
        end)
      end)

    render_error(conn, 422, "validation_failed", "The request is invalid", details)
  end

  def call(conn, {:error, {:missing_fields, fields}}) do
    render_error(conn, 422, "missing_fields", "Required fields are missing", %{fields: fields})
  end

  def call(conn, {:error, reason}) do
    {status, code, detail} = error(reason)
    render_error(conn, status, code, detail)
  end

  defp error(reason)
       when reason in [:invalid_credentials, :invalid_refresh_token, :invalid_access_token],
       do: {401, "unauthenticated", "Authentication failed"}

  defp error(:forbidden), do: {403, "forbidden", "This operation is not permitted"}
  defp error(:not_found), do: {404, "not_found", "The requested resource was not found"}

  defp error(:conversation_not_found),
    do: {404, "conversation_not_found", "The conversation was not found"}

  defp error(:attachment_not_ready),
    do: {409, "attachment_not_ready", "The attachment is not ready"}

  defp error(:attachment_not_pending),
    do: {409, "attachment_not_pending", "The attachment is not pending"}

  defp error(:object_not_found),
    do: {409, "object_not_found", "The uploaded object was not found"}

  defp error(:object_size_mismatch),
    do: {422, "object_size_mismatch", "The uploaded object size does not match"}

  defp error(:object_checksum_mismatch),
    do: {422, "object_checksum_mismatch", "The uploaded object checksum metadata does not match"}

  defp error(:direct_conversation_exists),
    do: {409, "conversation_exists", "The direct conversation already exists"}

  defp error(:cannot_remove_owner),
    do: {409, "cannot_remove_owner", "The conversation owner cannot be removed"}

  defp error(reason)
       when reason in [
              :weak_password,
              :invalid_members,
              :direct_conversation_requires_two_members,
              :identity_mismatch,
              :message_body_required,
              :message_too_large,
              :too_many_attachments,
              :duplicate_attachment_ids,
              :invalid_attachment_id,
              :metadata_too_many_properties,
              :metadata_too_large,
              :invalid_reply_target,
              :invalid_message_body,
              :idempotency_key_required,
              :invalid_idempotency_key,
              :invalid_sequence,
              :search_query_required,
              :unsupported_content_type,
              :invalid_attachment_size,
              :invalid_attachment_checksum,
              :attachment_checksum_mismatch,
              :invalid_attachments
            ],
       do: {422, Atom.to_string(reason), "The request could not be processed"}

  defp error(_), do: {500, "internal_error", "The request could not be completed"}

  defp render_error(conn, status, code, detail, meta \\ nil) do
    error = %{code: code, detail: detail}
    error = if is_nil(meta), do: error, else: Map.put(error, :meta, meta)

    conn
    |> put_status(status)
    |> json(%{error: error})
  end
end
