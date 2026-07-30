defmodule CommsCore.Attachments.FileQueries do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Accounts, Conversations, Repo}
  alias CommsCore.Attachments.{Attachment, FileView, Projector}

  @default_file_limit 30
  @max_file_limit 100

  @doc """
  Lists message-owned files visible to an active human subject.

  The query is contained by ConversationContent, validates the current
  identity session before selecting tenant data, and limits the source
  conversations to active memberships. Archived, departed, deleted, and
  moderated sources are excluded. Unsafe files remain visible with their
  safety state but never expose storage identity.
  """
  @spec list_files(map(), map()) ::
          {:ok,
           %{
             files: [FileView.t()],
             limit: pos_integer(),
             has_more: boolean(),
             next_cursor: String.t() | nil
           }}
          | {:error,
             :forbidden
             | :invalid_file_scope
             | :invalid_conversation_id
             | :invalid_cursor}
  def list_files(subject, params \\ %{})

  def list_files(subject, params) when is_map(subject) and is_map(params) do
    with {:ok, grant} <- Accounts.access_grant(subject),
         {:ok, scope} <- file_scope(value(params, :scope)),
         {:ok, conversation_id} <- optional_file_conversation(value(params, :conversation_id)),
         {:ok, cursor} <- optional_file_cursor(value(params, :cursor)) do
      authorization_query = Conversations.active_membership_authorization_query(grant)

      with :ok <- authorize_file_conversation(conversation_id, grant) do
        limit = file_limit(value(params, :limit))

        results =
          from(attachment in Attachment,
            as: :attachment,
            join: message in "messages",
            as: :message,
            on:
              type(field(message, :id), :binary_id) == attachment.message_id and
                type(field(message, :tenant_id), :binary_id) == attachment.tenant_id,
            join: authorization in subquery(authorization_query),
            as: :conversation_authorization,
            on:
              authorization.conversation_id ==
                type(field(message, :conversation_id), :binary_id),
            where:
              attachment.tenant_id == ^grant.tenant_id and
                field(message, :status) == "active" and attachment.status != :deleted and
                not is_nil(attachment.message_id),
            order_by: [desc: field(message, :inserted_at), desc: attachment.id],
            select: %{
              attachment: attachment,
              conversation_id: type(field(message, :conversation_id), :binary_id),
              conversation_sequence: type(field(message, :conversation_sequence), :integer),
              shared_at: type(field(message, :inserted_at), :utc_datetime_usec)
            }
          )
          |> maybe_filter_file_scope(scope, grant.user_id)
          |> maybe_filter_file_conversation(conversation_id)
          |> maybe_before_file_cursor(cursor)
          |> limit(^(limit + 1))
          |> Repo.all()

        has_more = length(results) > limit
        files = results |> Enum.take(limit) |> Projector.files()

        {:ok,
         %{
           files: files,
           limit: limit,
           has_more: has_more,
           next_cursor: if(has_more, do: file_cursor_for(List.last(files)), else: nil)
         }}
      end
    end
  end

  def list_files(_subject, _params), do: {:error, :forbidden}

  def list_for_message(message_id) do
    Attachment
    |> where(
      [a],
      a.message_id == ^message_id and a.status == :ready and a.scan_status == :clean and
        not is_nil(a.object_version_id) and
        a.verified_checksum_sha256 == a.checksum_sha256
    )
    |> order_by([a], asc: a.inserted_at)
    |> Repo.all()
    |> Projector.attachments()
  end

  defp file_scope(nil), do: {:ok, :recent}
  defp file_scope(""), do: {:ok, :recent}
  defp file_scope(:recent), do: {:ok, :recent}
  defp file_scope("recent"), do: {:ok, :recent}
  defp file_scope(:shared_by_me), do: {:ok, :shared_by_me}
  defp file_scope("shared_by_me"), do: {:ok, :shared_by_me}
  defp file_scope(_value), do: {:error, :invalid_file_scope}

  defp optional_file_conversation(nil), do: {:ok, nil}
  defp optional_file_conversation(""), do: {:ok, nil}

  defp optional_file_conversation(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, conversation_id} -> {:ok, conversation_id}
      :error -> {:error, :invalid_conversation_id}
    end
  end

  defp optional_file_conversation(_value), do: {:error, :invalid_conversation_id}

  defp authorize_file_conversation(nil, _grant), do: :ok

  defp authorize_file_conversation(conversation_id, grant) do
    if Conversations.active_conversation_member?(grant, conversation_id),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp maybe_filter_file_scope(query, :recent, _user_id), do: query

  defp maybe_filter_file_scope(query, :shared_by_me, user_id),
    do: where(query, [attachment: attachment], attachment.owner_user_id == ^user_id)

  defp maybe_filter_file_conversation(query, nil), do: query

  defp maybe_filter_file_conversation(query, conversation_id),
    do:
      where(
        query,
        [message: message],
        type(field(message, :conversation_id), :binary_id) == ^conversation_id
      )

  defp optional_file_cursor(nil), do: {:ok, nil}
  defp optional_file_cursor(""), do: {:ok, nil}

  defp optional_file_cursor(value) when is_binary(value) do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         {:ok, %{"shared_at" => shared_at, "id" => id, "v" => 1}} <- Jason.decode(decoded),
         {:ok, timestamp, _offset} <- DateTime.from_iso8601(shared_at),
         {:ok, attachment_id} <- Ecto.UUID.cast(id) do
      {:ok, {DateTime.truncate(timestamp, :microsecond), attachment_id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp optional_file_cursor(_value), do: {:error, :invalid_cursor}

  defp maybe_before_file_cursor(query, nil), do: query

  defp maybe_before_file_cursor(query, {timestamp, attachment_id}) do
    where(
      query,
      [attachment: attachment, message: message],
      type(field(message, :inserted_at), :utc_datetime_usec) < ^timestamp or
        (type(field(message, :inserted_at), :utc_datetime_usec) == ^timestamp and
           attachment.id < ^attachment_id)
    )
  end

  defp file_cursor_for(nil), do: nil

  defp file_cursor_for(%FileView{} = file) do
    %{v: 1, shared_at: DateTime.to_iso8601(file.shared_at), id: file.id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp file_limit(value) when is_integer(value),
    do: value |> max(1) |> min(@max_file_limit)

  defp file_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> file_limit(number)
      _ -> @default_file_limit
    end
  end

  defp file_limit(_value), do: @default_file_limit

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
