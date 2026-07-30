defmodule CommsCore.Accounts.Sessions.SocketTickets do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Accounts.{Session, SocketTicket, User}
  alias CommsCore.Accounts.Sessions.Persistence
  alias CommsCore.Repo

  @session_bytes 32

  def issue(subject) when is_map(subject) do
    session_id = Persistence.value(subject, :session_id)

    with {:ok, session} <- Persistence.get_active(session_id),
         true <- session.tenant_id == Persistence.value(subject, :tenant_id),
         true <- session.user_id == Persistence.value(subject, :user_id),
         true <- session.device_id == Persistence.value(subject, :device_id) do
      issue_for(session, subject, %{})
    else
      _ -> {:error, :invalid_access_token}
    end
  end

  def issue_guest(subject) when is_map(subject) do
    session_id = Persistence.value(subject, :session_id)

    with {:ok, session, _tenant} <- Persistence.active_guest_with_tenant(session_id),
         true <- session.tenant_id == Persistence.value(subject, :tenant_id),
         true <- session.user_id == Persistence.value(subject, :user_id),
         true <- session.device_id == Persistence.value(subject, :device_id),
         {:ok, access_scope} <- guest_access_scope(subject, session) do
      issue_for(session, subject, access_scope)
    else
      _ -> {:error, :invalid_access_token}
    end
  end

  def issue_guest(_subject), do: {:error, :invalid_access_token}

  def consume(ticket) when is_binary(ticket) do
    with {:ok, ticket_id, secret} <- parse(ticket) do
      Repo.transaction(fn ->
        record =
          Repo.one(from(t in SocketTicket, where: t.id == ^ticket_id, lock: "FOR UPDATE")) ||
            Repo.rollback(:invalid_socket_ticket)

        unless is_nil(record.consumed_at) and
                 DateTime.compare(record.expires_at, Persistence.now()) == :gt and
                 secure_hash_equals(record.token_hash, secret),
               do: Repo.rollback(:invalid_socket_ticket)

        session =
          case active_session(record.session_id) do
            {:ok, %Session{} = session} -> session
            _ -> Repo.rollback(:invalid_socket_ticket)
          end

        unless session.tenant_id == record.tenant_id and session.user_id == record.user_id and
                 session.device_id == record.device_id,
               do: Repo.rollback(:invalid_socket_ticket)

        record
        |> SocketTicket.changeset(%{consumed_at: Persistence.now()})
        |> update_or_rollback()

        subject = socket_subject(session, record.access_scope, "socket-connect")

        Persistence.insert_audit!(
          subject,
          "socket_ticket.consume",
          "session",
          session.id,
          %{ticket_id: record.id}
        )

        subject
      end)
      |> Persistence.transaction_result()
    else
      _ -> {:error, :invalid_socket_ticket}
    end
  end

  def consume(_ticket), do: {:error, :invalid_socket_ticket}

  defp active_session(id) do
    case Persistence.active_with_tenant(id) do
      {:ok, session, _tenant} -> {:ok, session}
      _ -> Persistence.active_guest_with_tenant(id) |> socket_session_result()
    end
  end

  defp socket_session_result({:ok, session, _tenant}), do: {:ok, session}
  defp socket_session_result(_result), do: {:error, :session_expired}

  defp issue_for(%Session{} = session, subject, access_scope) do
    ticket_id = Ecto.UUID.generate()
    secret = :crypto.strong_rand_bytes(@session_bytes)
    ticket = "#{ticket_id}.#{Base.url_encode64(secret, padding: false)}"
    issued_at = Persistence.now()

    configured_ttl =
      Application.get_env(:comms_core, :socket_ticket_ttl_seconds, 60) |> min(120) |> max(10)

    ticket_expires_at =
      DateTime.add(issued_at, configured_ttl, :second)
      |> earlier_deadline(session.expires_at)
      |> earlier_deadline(session.absolute_expires_at)
      |> earlier_optional_deadline(scope_deadline(access_scope))

    expires_in = max(DateTime.diff(ticket_expires_at, issued_at, :second), 1)

    Repo.transaction(fn ->
      prune!()

      %SocketTicket{id: ticket_id}
      |> SocketTicket.changeset(%{
        tenant_id: session.tenant_id,
        user_id: session.user_id,
        device_id: session.device_id,
        session_id: session.id,
        token_hash: :crypto.hash(:sha256, secret),
        access_scope: access_scope,
        expires_at: ticket_expires_at
      })
      |> insert_or_rollback()

      Persistence.insert_audit!(
        subject,
        "socket_ticket.issue",
        "session",
        session.id,
        %{
          ticket_id: ticket_id,
          expires_in: expires_in,
          guest_scoped: map_size(access_scope) > 0
        }
      )

      %{ticket: ticket, expires_in: expires_in}
    end)
    |> Persistence.transaction_result()
  end

  defp guest_access_scope(subject, %Session{user: %User{} = user} = session) do
    conversation_id = Persistence.value(subject, :guest_conversation_id)
    admission_id = Persistence.value(subject, :guest_admission_id)
    history_from_sequence = Persistence.value(subject, :guest_history_from_sequence)
    claimed_expiry = Persistence.value(subject, :guest_expires_at)

    with {:ok, _conversation_uuid} <- Ecto.UUID.cast(conversation_id),
         {:ok, _admission_uuid} <- Ecto.UUID.cast(admission_id),
         true <- is_integer(history_from_sequence) and history_from_sequence >= 0,
         {:ok, expiry} <- cast_datetime(claimed_expiry),
         true <- user.account_type == :guest,
         true <- DateTime.compare(expiry, Persistence.now()) == :gt,
         true <- deadline_not_after?(expiry, user.guest_expires_at),
         true <- deadline_not_after?(expiry, session.expires_at),
         true <- deadline_not_after?(expiry, session.absolute_expires_at) do
      {:ok,
       %{
         "account_type" => "guest",
         "guest_admission_id" => admission_id,
         "guest_conversation_id" => conversation_id,
         "guest_history_from_sequence" => history_from_sequence,
         "guest_expires_at" => DateTime.to_iso8601(expiry)
       }}
    else
      _ -> {:error, :invalid_guest_scope}
    end
  end

  defp socket_subject(
         %Session{user: %User{account_type: :human}} = session,
         scope,
         request_id
       )
       when scope == %{} or is_nil(scope),
       do: Persistence.subject(session, request_id)

  defp socket_subject(
         %Session{user: %User{account_type: :guest} = user} = session,
         %{
           "account_type" => "guest",
           "guest_admission_id" => admission_id,
           "guest_conversation_id" => conversation_id,
           "guest_history_from_sequence" => history_from_sequence,
           "guest_expires_at" => expiry_text
         },
         request_id
       ) do
    with {:ok, _conversation_uuid} <- Ecto.UUID.cast(conversation_id),
         {:ok, _admission_uuid} <- Ecto.UUID.cast(admission_id),
         true <- is_integer(history_from_sequence) and history_from_sequence >= 0,
         {:ok, expiry} <- cast_datetime(expiry_text),
         true <- DateTime.compare(expiry, Persistence.now()) == :gt,
         true <- deadline_not_after?(expiry, user.guest_expires_at),
         true <- deadline_not_after?(expiry, session.expires_at),
         true <- deadline_not_after?(expiry, session.absolute_expires_at) do
      session
      |> Persistence.subject(request_id)
      |> Map.merge(%{
        account_type: :guest,
        guest_admission_id: admission_id,
        guest_conversation_id: conversation_id,
        guest_history_from_sequence: history_from_sequence,
        guest_expires_at: expiry
      })
    else
      _ -> Repo.rollback(:invalid_socket_ticket)
    end
  end

  defp socket_subject(_session, _scope, _request_id),
    do: Repo.rollback(:invalid_socket_ticket)

  defp scope_deadline(%{"account_type" => "guest", "guest_expires_at" => expiry}) do
    case cast_datetime(expiry) do
      {:ok, deadline} -> deadline
      _ -> nil
    end
  end

  defp scope_deadline(_scope), do: nil

  defp parse(ticket) do
    case String.split(ticket, ".", parts: 2) do
      [id, encoded] ->
        with {:ok, _uuid} <- Ecto.UUID.cast(id),
             {:ok, secret} <- Base.url_decode64(encoded, padding: false),
             true <- byte_size(secret) == @session_bytes do
          {:ok, id, secret}
        else
          _ -> {:error, :invalid_socket_ticket}
        end

      _ ->
        {:error, :invalid_socket_ticket}
    end
  end

  defp prune! do
    retention = Application.get_env(:comms_core, :socket_ticket_retention_seconds, 3_600)
    cutoff = DateTime.add(Persistence.now(), -max(retention, 0), :second)

    stale_ids =
      from(t in SocketTicket,
        where: t.expires_at < ^cutoff or (not is_nil(t.consumed_at) and t.consumed_at < ^cutoff),
        order_by: [asc: t.expires_at],
        limit: 500,
        select: t.id
      )

    Repo.delete_all(from(t in SocketTicket, where: t.id in subquery(stale_ids)))
    :ok
  end

  defp secure_hash_equals(hash, secret) when is_binary(hash) and is_binary(secret) do
    actual = :crypto.hash(:sha256, secret)
    byte_size(actual) == byte_size(hash) and :crypto.hash_equals(actual, hash)
  end

  defp secure_hash_equals(_, _), do: false

  defp cast_datetime(%DateTime{} = value),
    do: {:ok, DateTime.truncate(value, :microsecond)}

  defp cast_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> {:ok, DateTime.truncate(parsed, :microsecond)}
      _ -> {:error, :invalid_datetime}
    end
  end

  defp cast_datetime(_value), do: {:error, :invalid_datetime}

  defp earlier_deadline(first, second) do
    if DateTime.compare(first, second) == :gt, do: second, else: first
  end

  defp earlier_optional_deadline(first, %DateTime{} = second),
    do: earlier_deadline(first, second)

  defp earlier_optional_deadline(first, _second), do: first

  defp deadline_not_after?(%DateTime{} = deadline, %DateTime{} = authority_deadline),
    do: DateTime.compare(deadline, authority_deadline) in [:lt, :eq]

  defp deadline_not_after?(_deadline, _authority_deadline), do: false

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
