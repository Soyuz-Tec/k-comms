defmodule CommsCore.Messaging.BoardAssets do
  @moduledoc "Approved content adapter for the Collaboration asset contract."
  @behaviour CommsCore.Whiteboards.BoardAssetPort
  import Ecto.Query
  alias CommsCore.{Conversations, Repo}
  alias CommsCore.Attachments.Attachment
  alias CommsCore.Messaging.Message
  alias CommsCore.Whiteboards.BoardAssetReceipt
  @raster_types ~w(image/png image/jpeg image/webp image/gif)

  @spec claim(binary(), binary(), map()) :: {:ok, BoardAssetReceipt.t()} | {:error, atom()}
  @impl true
  def claim(attachment_id, conversation_id, subject) do
    if Repo.in_transaction?() do
      with {:ok, receipt} <- approved(attachment_id, nil, conversation_id, subject, true) do
        {:ok, receipt}
      end
    else
      {:error, :transaction_required}
    end
  end

  @spec read(binary(), binary(), binary(), map()) ::
          {:ok, BoardAssetReceipt.t()} | {:error, atom()}
  @impl true
  def read(attachment_id, source_message_id, conversation_id, subject),
    do: approved(attachment_id, source_message_id, conversation_id, subject, false)

  defp approved(attachment_id, source_message_id, conversation_id, subject, claim?) do
    with :ok <- Conversations.authorize_read(conversation_id, subject) do
      query =
        from(a in Attachment,
          join: m in Message,
          on: m.id == a.message_id and m.tenant_id == a.tenant_id,
          where:
            a.id == ^attachment_id and a.tenant_id == ^value(subject, :tenant_id) and
              m.conversation_id == ^conversation_id and m.status == :active and
              a.status == :ready and a.scan_status == :clean and a.content_type in ^@raster_types and
              a.byte_size <= 10_485_760 and not is_nil(a.object_version_id) and
              not is_nil(a.object_etag) and a.object_etag != "" and
              a.object_version_id not in ["", "null"] and
              a.checksum_sha256 == a.verified_checksum_sha256,
          select: {a, m.id}
        )

      query =
        if claim?,
          do: query |> where([a, _m], a.owner_user_id == ^value(subject, :user_id)),
          else: query

      query =
        if source_message_id, do: where(query, [_a, m], m.id == ^source_message_id), else: query

      case Repo.one(query) do
        {a, message_id} ->
          {:ok,
           %BoardAssetReceipt{
             attachment_id: a.id,
             source_message_id: message_id,
             content_type: a.content_type,
             byte_size: a.byte_size,
             object_key: a.object_key,
             object_version_id: a.object_version_id,
             object_etag: a.object_etag,
             checksum_sha256: a.checksum_sha256,
             verified_checksum_sha256: a.verified_checksum_sha256
           }}

        nil ->
          {:error, :asset_unavailable}
      end
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
