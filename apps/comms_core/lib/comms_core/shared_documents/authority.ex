defmodule CommsCore.SharedDocuments.Authority do
  @moduledoc false
  alias CommsCore.{Accounts, Conversations, Repo}
  alias CommsCore.SharedDocuments.{Document, ProtectionPort}

  def deadline, do: System.monotonic_time(:millisecond) + 15_000

  def lock!(conversation_id, subject, deadline) do
    budget!(deadline)
    protect!(value(subject, :tenant_id), conversation_id, [value(subject, :user_id)], :admit)
    budget!(deadline)

    case Accounts.lock_content_write_grant(subject, deadline) do
      {:ok, %{account_type: :human, access_scope: :workspace}} -> :ok
      _ -> Repo.rollback(:forbidden)
    end

    budget!(deadline)
    # Tenant document capacity is owner-owned and is retained before every
    # conversation/document resource, including source documents for copying.
    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))",
      ["shared-document-tenant-capacity:#{value(subject, :tenant_id)}"]
    )

    budget!(deadline)

    case Conversations.lock_call_conversation(value(subject, :tenant_id), conversation_id, :share) do
      {:ok, _} -> :ok
      _ -> Repo.rollback(:forbidden)
    end

    current!(conversation_id, subject, deadline)
    # Instant-room authority has a separate expiry lifecycle. Shared documents
    # are durable workspace content and are never admitted to those rooms.
    case Conversations.ephemeral_room_for_conversation(conversation_id, subject) do
      {:ok, nil} -> :ok
      _ -> Repo.rollback(:forbidden)
    end

    current!(conversation_id, subject, deadline)
  end

  def current!(conversation_id, subject, deadline) do
    budget!(deadline)

    with {:ok, %{account_type: :human, access_scope: :workspace}} <-
           Accounts.access_grant(subject),
         :ok <- Conversations.authorize_read(conversation_id, subject) do
      budget!(deadline)
    else
      _ -> Repo.rollback(:forbidden)
    end
  end

  def document!(%Document{} = document, mode \\ :admit) do
    if document.erased_at, do: Repo.rollback(:not_found)

    unless document.lineage_verified and document.author_user_ids != [] and
             Enum.all?(document.author_user_ids, &match?({:ok, _}, Ecto.UUID.cast(&1))) do
      Repo.rollback(:document_lineage_unknown)
    end

    protect!(document.tenant_id, document.conversation_id, document.author_user_ids, mode)
  end

  def protect!(tenant_id, conversation_id, authors, mode) do
    case ProtectionPort.protection(tenant_id, conversation_id, authors) do
      {:ok, protection} ->
        cond do
          mode == :erase and protection.held -> Repo.rollback(:legal_hold_active)
          mode == :admit and protection.capture_blocked -> Repo.rollback(:forbidden)
          true -> protection
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  def budget!(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: Repo.rollback(:forbidden)
    timeout = Integer.to_string(remaining) <> "ms"

    Repo.query!(
      "SELECT set_config('lock_timeout', $1, true), set_config('statement_timeout', $1, true)",
      [timeout]
    )

    if System.monotonic_time(:millisecond) >= deadline, do: Repo.rollback(:forbidden)
    :ok
  end

  def value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
