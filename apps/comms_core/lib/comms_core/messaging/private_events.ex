defmodule CommsCore.Messaging.PrivateEvents do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Accounts, Conversations, Repo}

  alias CommsCore.Messaging.{
    PrivateBudget,
    PrivateEvent,
    PrivateEventView,
    PrivateEventCommand,
    PrivateEventReceipt,
    PrivateEventPort
  }

  @max_events 10_000

  def send_encrypted(conversation, attrs, subject) do
    deadline = PrivateBudget.new()

    with :ok <- validate(attrs),
         {:ok, client} <- Accounts.matrix_client_session(subject, deadline),
         {:ok, {event, _grant}} <-
           transaction(conversation, attrs, subject, deadline, fn grant ->
             claim!(grant, client, attrs)
           end) do
      if event.state == :retained do
        {:ok, %{event: project(event), replayed: true}}
      else
        with {:ok, {retained, _}} <-
               transaction(conversation, attrs, subject, deadline, fn current ->
                 stored =
                   Repo.one!(
                     from(e in PrivateEvent,
                       where: e.id == ^event.id and e.tenant_id == ^current.tenant_id,
                       lock: "FOR UPDATE"
                     )
                   )

                 if stored.state == :erased or stored.generation != current.generation,
                   do: Repo.rollback(:private_room_generation_stale)

                 # Durable pending intent survives lost provider ACKs. Current
                 # identity, Governance and room authority stay retained through
                 # the actual native send and verified provider receipt.
                 command = %PrivateEventCommand{
                   grant: current,
                   client_session: client,
                   transaction_id: stored.transaction_id,
                   content: stored.content
                 }

                 receipt =
                   case PrivateEventPort.send_encrypted(command) do
                     {:ok, %PrivateEventReceipt{} = receipt} -> receipt
                     {:error, reason} -> Repo.rollback(reason)
                   end

                 PrivateBudget.check!(current.deadline)

                 case receipt_matches(receipt, stored) do
                   :ok -> :ok
                   {:error, reason} -> Repo.rollback(reason)
                 end

                 case Accounts.access_grant(subject) do
                   {:ok, _} -> :ok
                   _ -> Repo.rollback(:forbidden)
                 end

                 Repo.update!(
                   Ecto.Changeset.change(stored,
                     state: :retained,
                     matrix_event_id: receipt.matrix_event_id
                   )
                 )
               end) do
          {:ok, %{event: project(retained), replayed: false}}
        end
      end
    end
  end

  def replay(id, attrs, subject) do
    deadline = PrivateBudget.new()
    after_sequence = value(attrs, :after_sequence) || 0

    if is_integer(after_sequence) and after_sequence in 0..@max_events do
      with {:ok, {{events, pending}, grant}} <-
             transaction(id, attrs, subject, deadline, fn grant ->
               events =
                 Repo.all(
                   from(e in PrivateEvent,
                     where:
                       e.tenant_id == ^grant.tenant_id and e.conversation_id == ^id and
                         e.sequence > ^after_sequence and e.state == :retained and
                         e.generation <= ^grant.generation,
                     order_by: e.sequence,
                     limit: 101
                   )
                 )

               pending =
                 Repo.all(
                   from(e in PrivateEvent,
                     where:
                       e.tenant_id == ^grant.tenant_id and e.conversation_id == ^id and
                         e.author_session_id == ^grant.session_id and e.state == :pending and
                         e.generation == ^grant.generation and
                         e.membership_epoch == ^grant.membership_epoch,
                     order_by: e.sequence,
                     limit: 33
                   )
                 )

               if length(pending) > 32, do: Repo.rollback(:private_pending_capacity_exhausted)
               {events, pending}
             end) do
        {:ok,
         %{
           events: events |> Enum.take(100) |> Enum.map(&project/1),
           pending_intents: Enum.map(pending, &intent/1),
           has_more: length(events) > 100,
           generation: grant.generation,
           membership_epoch: grant.membership_epoch
         }}
      end
    else
      {:error, :invalid_private_cursor}
    end
  end

  defp transaction(id, attrs, subject, deadline, operation) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         epoch when is_integer(epoch) and epoch > 0 <- value(attrs, :membership_epoch),
         generation when is_integer(generation) and generation > 0 <- value(attrs, :generation) do
      PrivateBudget.transaction(deadline, fn ->
        case Conversations.lock_private_room_grant(id, subject, epoch, generation, deadline) do
          {:ok, grant} -> {operation.(grant), grant}
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      _ -> {:error, :invalid_private_generation}
    end
  end

  defp claim!(grant, client, attrs) do
    if client.k_session_id != grant.session_id or client.matrix_user_id != grant.matrix_user_id or
         DateTime.diff(client.expires_at, DateTime.utc_now(), :millisecond) < 10_000,
       do: Repo.rollback(:matrix_device_binding_unconfirmed)

    if Repo.aggregate(
         from(e in PrivateEvent,
           where:
             e.tenant_id == ^grant.tenant_id and e.conversation_id == ^grant.conversation_id and
               e.author_session_id == ^grant.session_id and e.state == :pending
         ),
         :count
       ) >= 32 and
         not Repo.exists?(
           from(e in PrivateEvent,
             where:
               e.tenant_id == ^grant.tenant_id and e.conversation_id == ^grant.conversation_id and
                 e.author_session_id == ^grant.session_id and
                 e.transaction_id == ^value(attrs, :transaction_id)
           )
         ),
       do: Repo.rollback(:private_pending_capacity_exhausted)

    content = value(attrs, :content)

    if content["device_id"] && content["device_id"] != client.matrix_device_id,
      do: Repo.rollback(:matrix_device_binding_unconfirmed)

    transaction_id = value(attrs, :transaction_id)

    fingerprint =
      :crypto.hash(
        :sha256,
        Jason.encode!(Enum.map(Enum.sort(content), fn {key, value} -> [key, value] end))
      )

    old =
      Repo.one(
        from(e in PrivateEvent,
          where:
            e.tenant_id == ^grant.tenant_id and e.conversation_id == ^grant.conversation_id and
              e.author_session_id == ^grant.session_id and e.transaction_id == ^transaction_id,
          lock: "FOR UPDATE"
        )
      )

    if old do
      if old.input_fingerprint != fingerprint or old.state == :erased or
           old.generation != grant.generation or old.membership_epoch != grant.membership_epoch,
         do: Repo.rollback(:idempotency_conflict)

      old
    else
      query =
        from(e in PrivateEvent,
          where: e.tenant_id == ^grant.tenant_id and e.conversation_id == ^grant.conversation_id
        )

      count = Repo.aggregate(query, :count)
      if count >= @max_events, do: Repo.rollback(:private_event_capacity_exhausted)

      if Repo.aggregate(from(e in PrivateEvent, where: e.tenant_id == ^grant.tenant_id), :count) >=
           100_000,
         do: Repo.rollback(:private_event_capacity_exhausted)

      Repo.insert!(%PrivateEvent{
        tenant_id: grant.tenant_id,
        conversation_id: grant.conversation_id,
        author_user_id: grant.user_id,
        author_device_id: grant.device_id,
        author_session_id: grant.session_id,
        matrix_room_id: grant.matrix_room_id,
        matrix_sender: grant.matrix_user_id,
        membership_epoch: grant.membership_epoch,
        generation: grant.generation,
        transaction_id: transaction_id,
        input_fingerprint: fingerprint,
        content: content,
        sequence: count + 1
      })
    end
  end

  def validate(attrs) when is_map(attrs) do
    content = value(attrs, :content)
    txn = value(attrs, :transaction_id)
    allowed = ["algorithm", "ciphertext", "session_id", "device_id", "sender_key"]

    if is_binary(txn) and Regex.match?(~r/\A[A-Za-z0-9_.-]{1,128}\z/, txn) and is_map(content) and
         map_size(content) in 3..5 and Enum.all?(Map.keys(content), &(&1 in allowed)) and
         content["algorithm"] == "m.megolm.v1.aes-sha2" and
         base64?(content["ciphertext"], 32, 65_536) and base64?(content["session_id"], 32, 32) and
         (is_nil(content["sender_key"]) or base64?(content["sender_key"], 32, 32)) and
         (is_nil(content["device_id"]) or
            (is_binary(content["device_id"]) and
               Regex.match?(~r/\A[A-Za-z0-9_.-]{1,128}\z/, content["device_id"]))) and
         byte_size(Jason.encode!(content)) <= 65_536 do
      :ok
    else
      {:error, :invalid_opaque_private_event}
    end
  end

  def validate(_), do: {:error, :invalid_opaque_private_event}

  defp base64?(value, min, max) when is_binary(value) do
    case Base.decode64(value, padding: false) do
      {:ok, bytes} -> byte_size(bytes) in min..max
      _ -> false
    end
  end

  defp base64?(_, _, _), do: false

  defp receipt_matches(receipt, event) do
    if receipt.matrix_room_id == event.matrix_room_id and
         receipt.matrix_sender == event.matrix_sender and receipt.content == event.content and
         is_binary(receipt.matrix_event_id) and byte_size(receipt.matrix_event_id) in 1..512,
       do: :ok,
       else: {:error, :private_event_provider_receipt_invalid}
  end

  def project(event),
    do: %PrivateEventView{
      id: event.id,
      conversation_id: event.conversation_id,
      sequence: event.sequence,
      matrix_event_id: event.matrix_event_id,
      matrix_room_id: event.matrix_room_id,
      matrix_sender: event.matrix_sender,
      author_user_id: event.author_user_id,
      membership_epoch: event.membership_epoch,
      generation: event.generation,
      content: event.content,
      state: event.state
    }

  defp intent(event),
    do: %CommsCore.Messaging.PrivateEventIntentView{
      transaction_id: event.transaction_id,
      content: event.content,
      membership_epoch: event.membership_epoch,
      generation: event.generation
    }

  def erase(%CommsCore.Conversations.PrivateContentErasureCommand{} = command) do
    with :ok <- Conversations.authorize_private_content_erasure(command) do
      {count, _} =
        Repo.update_all(
          from(e in PrivateEvent,
            where:
              e.tenant_id == ^command.tenant_id and e.conversation_id == ^command.conversation_id and
                e.state != :erased
          ),
          set: [
            content: nil,
            input_fingerprint: nil,
            state: :erased,
            erased_at: command.timestamp
          ]
        )

      {:ok, %CommsCore.Conversations.PrivateContentErasureReceipt{opaque_events_erased: count}}
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
