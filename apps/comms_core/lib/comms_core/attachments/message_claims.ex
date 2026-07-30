defmodule CommsCore.Attachments.MessageClaims do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Repo
  alias CommsCore.Attachments.Attachment

  @doc """
  Claims ready attachments for a message inside the caller's transaction.

  Messaging owns the surrounding message transaction; this contributed write
  refuses to run independently so the message and attachment claims cannot
  commit separately.
  """
  @spec attach_ready([String.t()], String.t(), String.t(), map()) ::
          :ok | {:error, :transaction_required}
  def attach_ready(ids, message_id, tenant_id, subject)
      when is_list(ids) and is_binary(message_id) and is_binary(tenant_id) do
    if Repo.in_transaction?() do
      attach_ready_in_transaction(Enum.uniq(ids), message_id, tenant_id, subject)
    else
      {:error, :transaction_required}
    end
  end

  defp attach_ready_in_transaction([], _message_id, _tenant_id, _subject), do: :ok

  defp attach_ready_in_transaction(ids, message_id, tenant_id, subject) do
    query =
      from(a in Attachment,
        where:
          a.id in ^ids and a.tenant_id == ^tenant_id and
            a.owner_user_id == ^value(subject, :user_id) and a.status == :ready and
            a.scan_status == :clean and not is_nil(a.object_version_id) and
            a.verified_checksum_sha256 == a.checksum_sha256 and is_nil(a.message_id)
      )

    {count, _} = Repo.update_all(query, set: [message_id: message_id, updated_at: now()])
    if count == length(ids), do: :ok, else: Repo.rollback(:invalid_attachments)
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
