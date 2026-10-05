defmodule CommsCore.Conversations.Federation.Commands do
  @moduledoc "Current-session commands. Lock order: Governance, quota/Tenant, User, Trust, Conversation, Room, Participant, Command."
  import Ecto.Query
  alias CommsCore.{Accounts, Repo, RuntimePorts}
  alias CommsCore.Accounts.{AccessGrant, FederationActorLockQuery}
  alias CommsCore.Conversations.{AccessPolicy, Conversation}

  alias CommsCore.Conversations.Federation.{
    Command,
    Domain,
    EventReceipt,
    Participant,
    ProviderReceipt,
    ProviderRequest,
    Room,
    SecretBox,
    Trust,
    View
  }

  @budget 15_000

  def trusts(subject) do
    with {:ok, grant} <- Accounts.access_grant(subject), :ok <- admin(grant, false) do
      {:ok,
       Repo.all(from(t in Trust, where: t.tenant_id == ^grant.tenant_id, order_by: t.domain))
       |> Enum.map(&trust_view/1)}
    end
  end

  def put_trust(attrs, subject) when is_map(attrs) do
    with {:ok, domain} <- Domain.validate(value(attrs, :domain)),
         {:ok, residency} <- text(value(attrs, :residency), 2, 80),
         {:ok, reason} <- text(value(attrs, :cross_border_reason), 10, 500),
         enabled when is_boolean(enabled) <- value(attrs, :enabled) do
      transaction(subject, nil, fn grant, _ ->
        ok!(admin(grant, true))

        trust =
          Repo.one(
            from(t in Trust,
              where: t.tenant_id == ^grant.tenant_id and t.domain == ^domain,
              lock: "FOR UPDATE"
            )
          )

        trust =
          if trust do
            version!(trust, attrs)

            update!(trust, Trust, %{
              residency: residency,
              cross_border_reason: reason,
              enabled: enabled
            })
          else
            bounded!(Trust, grant.tenant_id, 32)

            insert!(Trust, %{
              tenant_id: grant.tenant_id,
              domain: domain,
              residency: residency,
              cross_border_reason: reason,
              enabled: enabled
            })
          end

        if not enabled do
          Repo.all(
            from(r in Room,
              where: r.tenant_id == ^grant.tenant_id and r.trust_id == ^trust.id,
              order_by: r.id,
              lock: "FOR UPDATE"
            )
          )
          |> Enum.each(&fence_room!/1)
        end

        trust_view(trust)
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_federation_policy}
    end
  end

  def get(conversation_id, subject) do
    with :ok <- AccessPolicy.authorize_read(conversation_id, subject),
         {:ok, grant} <- Accounts.access_grant(subject),
         %Conversation{} = conversation <-
           Repo.get_by(Conversation, tenant_id: grant.tenant_id, id: conversation_id),
         :ok <- readable_mode(conversation) do
      room = Repo.get_by(Room, tenant_id: grant.tenant_id, conversation_id: conversation_id)
      {:ok, if(room, do: view(room, grant.user_id), else: nil)}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def create(conversation_id, attrs, subject) do
    with true <- value(attrs, :plaintext_disclosure_accepted) == true,
         {:ok, domain} <- Domain.validate(value(attrs, :domain)) do
      transaction(subject, conversation_id, fn grant, protection ->
        enabled!()
        unblocked!(protection)
        trust = trusted!(grant.tenant_id, domain)
        conversation = lock_conversation!(grant.tenant_id, conversation_id)
        ok!(AccessPolicy.authorize_manage(conversation_id, subject))
        if conversation.kind == :direct, do: Repo.rollback(:federation_group_required)

        if Repo.exists?(
             from(r in Room,
               where: r.tenant_id == ^grant.tenant_id and r.conversation_id == ^conversation_id
             )
           ),
           do: Repo.rollback(:federation_room_exists)

        bounded!(Room, grant.tenant_id, 100)
        {:ok, identity} = identity!(grant.tenant_id, grant.user_id)
        id = Ecto.UUID.generate()

        room =
          Repo.insert!(
            Room.changeset(%Room{id: id}, %{
              tenant_id: grant.tenant_id,
              conversation_id: conversation_id,
              trust_id: trust.id,
              created_by_user_id: grant.user_id,
              alias_localpart: "kc_fed_" <> String.replace(id, "-", ""),
              provider_issuer: Application.fetch_env!(:comms_core, :federation_homeserver_origin),
              provider_server_name: Application.fetch_env!(:comms_core, :federation_server_name),
              provider_bridge_user: Application.fetch_env!(:comms_core, :federation_bridge_user),
              status: "creating"
            })
          )

        put_participant!(room, grant.user_id, identity.matrix_user_id, "accepted")
        enqueue!(room, grant, "create", %{}, true)
        view(room, grant.user_id)
      end)
    else
      _ -> {:error, :plaintext_disclosure_required}
    end
  end

  def consent(conversation_id, attrs, subject) do
    transaction(subject, conversation_id, fn grant, protection ->
      room = room_for_command!(grant, conversation_id)
      version!(room, attrs)

      case value(attrs, :accept) do
        true ->
          enabled!()
          unblocked!(protection)
          active!(room)

          if value(attrs, :plaintext_disclosure_accepted) != true,
            do: Repo.rollback(:plaintext_disclosure_required)

          existing =
            Repo.get_by(Participant,
              tenant_id: room.tenant_id,
              room_id: room.id,
              user_id: grant.user_id
            )

          if existing && existing.withdrawn_at,
            do: Repo.rollback(:withdrawn_consent_requires_new_room)

          {:ok, identity} = identity!(grant.tenant_id, grant.user_id)
          put_participant!(room, grant.user_id, identity.matrix_user_id, "accepted")
          enqueue!(room, grant, "invite_local", %{principal: identity.matrix_user_id}, true)

        false ->
          withdraw_user!(room, grant.user_id)

        _ ->
          Repo.rollback(:invalid_federation_consent)
      end

      room = update!(room, Room, %{})
      view(room, grant.user_id)
    end)
  end

  def invite(conversation_id, attrs, subject) do
    transaction(subject, conversation_id, fn grant, protection ->
      enabled!()
      unblocked!(protection)
      room = room_for_command!(grant, conversation_id)
      active!(room)
      version!(room, attrs)
      ok!(AccessPolicy.authorize_manage(conversation_id, subject))
      accepted!(room, grant.user_id)
      trust = Repo.get!(Trust, room.trust_id)
      principal = ok_value!(Domain.matrix_user(value(attrs, :matrix_user_id), trust.domain))
      bounded_room!(Participant, room, 100)
      put_participant!(room, nil, principal, "invited")
      enqueue!(room, grant, "invite", %{principal: principal}, true)
      room = update!(room, Room, %{})
      view(room, grant.user_id)
    end)
  end

  def send(conversation_id, attrs, subject) do
    with {:ok, body} <- text(value(attrs, :body), 1, 8_000),
         {:ok, request_id} <- Ecto.UUID.cast(value(attrs, :idempotency_key)) do
      transaction(subject, conversation_id, fn grant, protection ->
        enabled!()
        unblocked!(protection)
        room = room_for_command!(grant, conversation_id)
        active!(room)
        version!(room, attrs)
        accepted!(room, grant.user_id)
        bounded_pending!(room)

        command =
          enqueue!(
            room,
            grant,
            "send",
            %{body: body},
            true,
            "send:" <> grant.user_id <> ":" <> request_id
          )

        %{id: command.id, status: command.status, disclosure: "plaintext_bridge"}
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_idempotency_key}
    end
  end

  def close(conversation_id, attrs, subject) do
    transaction(subject, conversation_id, fn grant, protection ->
      if protection.held, do: Repo.rollback(:legal_hold_active)
      room = room_for_command!(grant, conversation_id)
      version!(room, attrs)
      ok!(AccessPolicy.authorize_manage(conversation_id, subject))
      fence_room!(room)
      view(Repo.get!(Room, room.id), grant.user_id)
    end)
  end

  def timeline(conversation_id, attrs, subject) do
    transaction(subject, conversation_id, fn grant, protection ->
      enabled!()
      unblocked!(protection)
      room = room_for_command!(grant, conversation_id)
      active!(room)
      accepted!(room, grant.user_id)
      {:ok, provider_room} = open!(room, :provider_room_box, "room")
      participants = participants!(room)
      cursor = cursor!(room, grant.user_id, value(attrs, :cursor))

      request = %ProviderRequest{
        operation: :timeline,
        transaction_id: Ecto.UUID.generate(),
        deadline: deadline(),
        room_id: provider_room,
        alias_localpart: room.alias_localpart,
        homeserver_origin: room.provider_issuer,
        server_name: room.provider_server_name,
        bridge_user: room.provider_bridge_user,
        allowed_servers: [Repo.get!(Trust, room.trust_id).domain],
        cursor: cursor,
        limit: 30,
        allowed_principals:
          participants |> Enum.filter(&is_nil(&1.record.withdrawn_at)) |> Enum.map(& &1.principal)
      }

      result = provider!(request)

      Enum.each(participants, fn p ->
        if p.principal in result.joined and is_nil(p.record.joined_observed_at),
          do:
            update!(p.record, Participant, %{
              joined_observed_at: now(),
              consent_status:
                if(is_nil(p.record.user_id), do: "accepted", else: p.record.consent_status)
            })
      end)

      events =
        Enum.map(result.events, fn event ->
          receipt = receipt!(room, nil, event.event_id, event.sender)

          %{
            id: receipt.id,
            sender: event.sender,
            body: event.body,
            timestamp: event.timestamp,
            disclosure: "plaintext_bridge"
          }
        end)

      sealed_cursor =
        if is_binary(result.cursor),
          do:
            SecretBox.seal(room.tenant_id, room.id, "cursor:" <> grant.user_id, result.cursor)
            |> Base.url_encode64(padding: false)

      %{events: events, cursor: sealed_cursor, remote_deletion_confirmed: false}
    end)
  end

  def export(conversation_id, subject) do
    transaction(subject, conversation_id, fn grant, _protection ->
      room = room_for_command!(grant, conversation_id)

      receipts =
        Repo.all(
          from(e in EventReceipt,
            where: e.tenant_id == ^room.tenant_id and e.room_id == ^room.id,
            order_by: e.id,
            limit: 1001
          )
        )

      %{
        room: Map.from_struct(view(room, grant.user_id)),
        export_scope: "local_metadata_only",
        remote_deletion_confirmed: false,
        incoming_content_persisted_locally: false,
        truncated: length(receipts) > 1000,
        receipts:
          Enum.map(
            Enum.take(receipts, 1000),
            &%{
              id: &1.id,
              observed_at: &1.observed_at,
              local_redaction_observed_at: &1.redacted_observed_at
            }
          )
      }
    end)
  end

  def deliver(id, caller, create_mode) when create_mode in [:first_attempt, :recovery_only] do
    if RuntimePorts.authorized_job_worker?(:federation_command, caller) do
      case Repo.get(Command, id) do
        nil ->
          {:error, :not_found}

        %Command{status: status} when status in ["done", "cancelled", "cancelled_unknown"] ->
          {:error, :already_terminal}

        seed ->
          deliver_command(seed, create_mode)
      end
    else
      {:error, :forbidden}
    end
  end

  defp deliver_command(seed, create_mode) do
    room_seed = Repo.get!(Room, seed.room_id)

    subject = %{
      tenant_id: seed.tenant_id,
      user_id: seed.user_id,
      device_id: seed.device_id,
      session_id: seed.session_id
    }

    cleanup? = seed.kind in ["redact", "recover_room", "recover_send", "leave", "close"]

    Repo.transaction(
      fn ->
        deadline = System.monotonic_time(:millisecond) + @budget
        Process.put({__MODULE__, :deadline}, deadline)

        protection!(seed.tenant_id, room_seed.conversation_id, [])

        protection =
          protection!(
            seed.tenant_id,
            room_seed.conversation_id,
            local_user_ids(room_seed, false)
          )

        budget!()

        if cleanup? do
          if protection.held, do: Repo.rollback(:legal_hold_active)
        else
          enabled!()
          unblocked!(protection)

          grant =
            ok_value!(
              Accounts.lock_federation_actor(%FederationActorLockQuery{
                subject: subject,
                local_participant_user_ids: local_user_ids(room_seed, true),
                deadline: deadline
              })
            )

          human!(grant)
          ok!(AccessPolicy.authorize_send_message(room_seed.conversation_id, subject))
        end

        trust = lock_trust!(seed.tenant_id, room_seed.trust_id)
        if not cleanup? and not trust.enabled, do: Repo.rollback(:federation_trust_disabled)
        lock_conversation!(seed.tenant_id, room_seed.conversation_id, cleanup?)

        room =
          Repo.one!(
            from(r in Room,
              where: r.id == ^seed.room_id and r.tenant_id == ^seed.tenant_id,
              lock: "FOR UPDATE"
            )
          )

        # Participant locks precede commands. Withdrawal uses the same ordering.
        if not cleanup?, do: accepted!(room, seed.user_id)

        command =
          Repo.one!(
            from(c in Command,
              where: c.id == ^seed.id and c.tenant_id == ^seed.tenant_id,
              lock: "FOR UPDATE"
            )
          )

        if command.status in ["done", "cancelled"], do: Repo.rollback(:already_terminal)

        if not cleanup? and
             (room.generation != command.generation or room.status == "fenced" or
                DateTime.compare(command.expires_at, now()) != :gt),
           do: Repo.rollback(:federation_command_stale)

        {:ok, payload} = open!(command, :payload_box, "command")
        op = operation(command.kind)

        if op == :close and
             Repo.exists?(
               from(c in Command,
                 where:
                   c.tenant_id == ^room.tenant_id and c.room_id == ^room.id and
                     c.id != ^command.id and
                     c.kind in ["redact", "recover_room", "recover_send", "leave"] and
                     c.status != "done"
               )
             ),
           do: Repo.rollback(:federation_cleanup_dependencies_pending)

        provider_room =
          if room.provider_room_box, do: ok_value!(open!(room, :provider_room_box, "room"))

        if cleanup? and op != :create and is_nil(provider_room),
          do: Repo.rollback(:federation_cleanup_room_pending)

        request = %ProviderRequest{
          operation: op,
          transaction_id: command.id,
          deadline: deadline,
          room_id: provider_room,
          alias_localpart: room.alias_localpart,
          homeserver_origin: room.provider_issuer,
          server_name: room.provider_server_name,
          bridge_user: room.provider_bridge_user,
          effect_mode:
            if(
              command.kind == "redact" and create_mode == :first_attempt and command.attempts == 1,
              do: :first_attempt,
              else: :recovery_only
            ),
          allowed_servers: [trust.domain],
          principal: payload["principal"],
          event_id: payload["event_id"],
          source_transaction_id: payload["source_transaction_id"],
          body:
            if(op == :create,
              do:
                if(
                  command.kind == "create" and create_mode == :first_attempt and
                    command.attempts == 1,
                  do: "first_attempt",
                  else: "recovery_only"
                ),
              else: payload["body"]
            ),
          allowed_principals:
            if(op == :create,
              do: [trust.domain],
              else:
                participants!(room)
                |> Enum.filter(&is_nil(&1.record.withdrawn_at))
                |> Enum.map(& &1.principal)
            )
        }

        # Persisting the attempt in this same transaction is insufficient on an effect
        # timeout. Create and redact have a separate durable first-attempt marker
        # committed before the worker enters; retries can only observe prior effects.
        result = CommsCore.Conversations.Federation.ProviderAdapter.perform(request)
        budget!()

        case result do
          {:ok, %ProviderReceipt{} = response} ->
            room =
              if op == :create do
                box = SecretBox.seal(room.tenant_id, room.id, "room", response.room_id)

                updated =
                  update!(room, Room, %{
                    provider_room_box: box,
                    status:
                      if(command.kind == "create" and is_nil(room.fenced_at),
                        do: "active",
                        else: room.status
                      )
                  })

                # Cleanup-only alias recovery never creates invitations or resumes sync.
                if command.kind == "create" and is_nil(updated.fenced_at),
                  do:
                    Enum.each(participants!(updated), fn p ->
                      enqueue_cleanup_or_invite!(updated, p.record, p.principal, subject)
                    end)

                updated
              else
                room
              end

            if op == :recover_event do
              receipt =
                receipt!(room, payload["source_transaction_id"], response.event_id, "bridge")

              enqueue!(
                room,
                nil,
                "redact",
                %{event_id: response.event_id, receipt_id: receipt.id},
                false
              )
            end

            if op == :send, do: receipt!(room, command.id, response.event_id, "bridge")

            if op == :redact and payload["receipt_id"] do
              receipt =
                Repo.get_by!(EventReceipt,
                  tenant_id: room.tenant_id,
                  room_id: room.id,
                  id: payload["receipt_id"]
                )

              receipt |> EventReceipt.changeset(%{redacted_observed_at: now()}) |> Repo.update!()
            end

            if cleanup?,
              do:
                update!(room, Room, %{
                  remote_cleanup_state: "remote_unconfirmed",
                  local_cleanup_confirmed_at: now()
                })

            command
            |> Command.changeset(%{
              status: "done",
              payload_box: nil,
              attempts: command.attempts + 1,
              last_error: nil,
              provider_receipt_box:
                SecretBox.seal(
                  command.tenant_id,
                  command.id,
                  "receipt",
                  Map.from_struct(response)
                )
            })
            |> Repo.update!()

            :ok

          {:error, reason} ->
            command
            |> Command.changeset(%{
              status: "uncertain",
              attempts: command.attempts + 1,
              last_error: Atom.to_string(reason)
            })
            |> Repo.update!()

            if cleanup?, do: update!(room, Room, %{remote_cleanup_state: "pending"})
            {:retry, reason}
        end
      end,
      timeout: @budget + 1_000
    )
  after
    Process.delete({__MODULE__, :deadline})
  end

  def reconcile(caller) do
    if RuntimePorts.authorized_job_worker?(:federation_reconcile, caller) do
      command_transaction(fn ->
        Repo.all(
          from(c in Command,
            where: c.status in ["pending", "prepared", "uncertain"],
            order_by: [asc: c.tenant_id, asc: c.room_id, asc: c.id],
            limit: 50,
            lock: "FOR UPDATE SKIP LOCKED"
          )
        )
        |> Enum.each(fn command ->
          job =
            Oban.Job.new(%{command_id: command.id},
              worker: RuntimePorts.job_worker_name!(:federation_command),
              queue: :lifecycle,
              max_attempts: 12,
              unique: [
                period: 60,
                fields: [:worker, :args],
                states: [:available, :scheduled, :executing, :retryable]
              ]
            )

          case Oban.insert(job) do
            {:ok, _} -> :ok
            {:error, _} -> Repo.rollback(:federation_job_unavailable)
          end
        end)

        :ok
      end)
    else
      {:error, :forbidden}
    end
  end

  def cancel_stale(id, caller) do
    if RuntimePorts.authorized_job_worker?(:federation_command, caller) do
      command_transaction(fn ->
        command = Repo.one(from(c in Command, where: c.id == ^id, lock: "FOR UPDATE"))

        if command &&
             command.kind not in ["redact", "recover_room", "recover_send", "leave", "close"] &&
             command.status != "done" do
          command
          |> Command.changeset(%{
            status: "cancelled_unknown",
            payload_box: nil,
            last_error: "current_authority_unavailable"
          })
          |> Repo.update!()
        end

        :ok
      end)
    else
      {:error, :forbidden}
    end
  end

  def claim_first_attempt(id, caller) do
    if RuntimePorts.authorized_job_worker?(:federation_command, caller) do
      command_transaction(fn ->
        command = Repo.one(from(c in Command, where: c.id == ^id, lock: "FOR UPDATE"))

        case command do
          %Command{kind: kind, attempts: 0, status: "pending"}
          when kind in ["create", "redact"] ->
            command |> Command.changeset(%{attempts: 1, status: "prepared"}) |> Repo.update!()
            :first_attempt

          %Command{} ->
            :recovery_only

          nil ->
            Repo.rollback(:not_found)
        end
      end)
    else
      {:error, :forbidden}
    end
  end

  # These contributions run while their caller already owns User or Conversation.
  # They never acquire Governance, User, Conversation or provider locks.
  def fence_user(tenant_id, user_id) do
    if Repo.in_transaction?() do
      Repo.all(
        from(p in Participant,
          where: p.tenant_id == ^tenant_id and p.user_id == ^user_id and is_nil(p.withdrawn_at),
          order_by: p.id,
          lock: "FOR UPDATE"
        )
      )
      |> Enum.each(fn p -> withdraw_participant!(p) end)

      {:ok, :fenced}
    else
      {:error, :transaction_required}
    end
  end

  def fence_conversation(tenant_id, conversation_id) do
    if Repo.in_transaction?() do
      case Repo.one(
             from(r in Room,
               where: r.tenant_id == ^tenant_id and r.conversation_id == ^conversation_id,
               lock: "FOR UPDATE"
             )
           ) do
        nil ->
          {:ok, :absent}

        room ->
          fence_room!(room)
          {:ok, :fenced}
      end
    else
      {:error, :transaction_required}
    end
  end

  def fence_member(tenant_id, conversation_id, user_id) do
    if Repo.in_transaction?() do
      case Repo.get_by(Room, tenant_id: tenant_id, conversation_id: conversation_id) do
        nil ->
          {:ok, :absent}

        room ->
          withdraw_user!(room, user_id)
          {:ok, :fenced}
      end
    else
      {:error, :transaction_required}
    end
  end

  def prepare_erasure(tenant_id, target_type, target) do
    if Repo.in_transaction?() do
      rooms = scope_rooms(tenant_id, target_type, target)

      if target_type == :user do
        Enum.each(rooms, &withdraw_user!(&1, target))
      else
        Enum.each(rooms, &fence_room!/1)
      end

      {:ok, length(rooms)}
    else
      {:error, :transaction_required}
    end
  end

  def erasure_pending?(tenant_id, type, target) do
    # Local Matrix redaction/leave is explicitly not a cross-server erasure receipt.
    {:ok,
     Enum.any?(scope_rooms(tenant_id, type, target), fn room ->
       room.remote_cleanup_state != "none" or
         Repo.exists?(
           from(c in Command,
             where:
               c.tenant_id == ^tenant_id and c.room_id == ^room.id and
                 c.kind in ["redact", "recover_room", "recover_send", "leave", "close"]
           )
         )
     end)}
  end

  def rollback_hazards(repo),
    do:
      Enum.filter(
        [
          {"federation_trusts", Trust},
          {"federation_rooms", Room},
          {"federation_participants", Participant},
          {"federation_commands", Command},
          {"federation_event_receipts", EventReceipt}
        ],
        fn {_, schema} -> repo.exists?(schema) end
      )
      |> Enum.map(&elem(&1, 0))

  def fingerprint(repo, tenant_id),
    do: %{
      federation_trusts: ids(repo, Trust, tenant_id),
      federation_rooms: ids(repo, Room, tenant_id),
      federation_participants: ids(repo, Participant, tenant_id),
      federation_commands: ids(repo, Command, tenant_id),
      federation_event_receipts: ids(repo, EventReceipt, tenant_id)
    }

  defp transaction(subject, conversation_id, fun) do
    tenant = value(subject, :tenant_id)
    user = value(subject, :user_id)

    Repo.transaction(
      fn ->
        deadline = System.monotonic_time(:millisecond) + @budget
        Process.put({__MODULE__, :deadline}, deadline)

        protection!(tenant, conversation_id, [])

        protected_users =
          [user | local_user_ids_for_conversation(tenant, conversation_id, false)] |> Enum.uniq()

        protection = protection!(tenant, conversation_id, protected_users)
        participants = local_user_ids_for_conversation(tenant, conversation_id, true)

        grant =
          ok_value!(
            Accounts.lock_federation_actor(%FederationActorLockQuery{
              subject: subject,
              local_participant_user_ids: participants,
              deadline: deadline
            })
          )

        human!(grant)
        result = fun.(grant, protection)
        budget!()
        result
      end,
      timeout: @budget + 1_000
    )
  after
    Process.delete({__MODULE__, :deadline})
  end

  defp command_transaction(fun) do
    Repo.transaction(
      fn ->
        Process.put({__MODULE__, :deadline}, System.monotonic_time(:millisecond) + @budget)
        budget!()
        result = fun.()
        budget!()
        result
      end,
      timeout: @budget + 1_000
    )
  after
    Process.delete({__MODULE__, :deadline})
  end

  defp protection!(tenant, conversation, users) do
    budget!()

    ok_value!(
      CommsCore.Conversations.Federation.ProtectionPort.protection(tenant, conversation, users)
    )
  end

  defp room_for_command!(grant, conversation_id) do
    seed =
      Repo.get_by(Room, tenant_id: grant.tenant_id, conversation_id: conversation_id) ||
        Repo.rollback(:not_found)

    trust = lock_trust!(grant.tenant_id, seed.trust_id)
    lock_conversation!(grant.tenant_id, conversation_id)

    ok!(
      AccessPolicy.authorize_read(conversation_id, %{
        tenant_id: grant.tenant_id,
        user_id: grant.user_id,
        device_id: grant.device_id,
        session_id: grant.session_id
      })
    )

    room =
      Repo.one!(
        from(r in Room,
          where: r.id == ^seed.id and r.tenant_id == ^grant.tenant_id,
          lock: "FOR UPDATE"
        )
      )

    if not trust.enabled and room.status != "fenced",
      do: Repo.rollback(:federation_trust_disabled)

    room
  end

  defp lock_conversation!(tenant, id, cleanup? \\ false) do
    budget!()

    conversation =
      Repo.one(
        from(c in Conversation,
          where: c.tenant_id == ^tenant and c.id == ^id and (^cleanup? or is_nil(c.archived_at)),
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:forbidden)

    if not cleanup?, do: ok!(readable_mode(conversation))
    conversation
  end

  # ADR-0104 adds the owned content_mode field. FAA's legacy rows are server-readable;
  # encrypted or unknown modes fail closed after the current Conversation lock.
  defp readable_mode(conversation) do
    if Map.get(conversation, :content_mode, :server_readable) == :server_readable,
      do: :ok,
      else: {:error, :encrypted_conversation_bridge_refused}
  end

  defp lock_trust!(tenant, id) do
    budget!()

    Repo.one(from(t in Trust, where: t.tenant_id == ^tenant and t.id == ^id, lock: "FOR UPDATE")) ||
      Repo.rollback(:federation_trust_disabled)
  end

  defp trusted!(tenant, domain) do
    trust =
      Repo.one(
        from(t in Trust,
          where: t.tenant_id == ^tenant and t.domain == ^domain,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:federation_trust_disabled)

    if not trust.enabled, do: Repo.rollback(:federation_trust_disabled)
    trust
  end

  defp identity!(tenant, user) do
    issuer = Application.get_env(:comms_core, :federation_homeserver_origin)
    server = Application.get_env(:comms_core, :federation_server_name)

    case Accounts.matrix_identity_view(tenant, user) do
      {:ok,
       %Accounts.MatrixIdentityView{
         tenant_id: ^tenant,
         user_id: ^user,
         issuer: ^issuer,
         provisioning_state: :ready
       } = view} ->
        case Domain.matrix_user(view.matrix_user_id, server) do
          {:ok, _} -> {:ok, view}
          _ -> Repo.rollback(:matrix_identity_not_ready)
        end

      _ ->
        Repo.rollback(:matrix_identity_not_ready)
    end
  end

  defp put_participant!(room, user, principal, status) do
    hash = SecretBox.hash(principal)

    case Repo.one(
           from(p in Participant,
             where:
               p.tenant_id == ^room.tenant_id and p.room_id == ^room.id and
                 p.principal_hash == ^hash,
             lock: "FOR UPDATE"
           )
         ) do
      nil ->
        bounded_room!(Participant, room, 100)
        id = Ecto.UUID.generate()

        Repo.insert!(
          Participant.changeset(%Participant{id: id}, %{
            tenant_id: room.tenant_id,
            room_id: room.id,
            user_id: user,
            principal_hash: hash,
            principal_box: SecretBox.seal(room.tenant_id, id, "principal", principal),
            consent_status: status
          })
        )

      p ->
        if p.withdrawn_at, do: Repo.rollback(:withdrawn_consent_requires_new_room)
        update!(p, Participant, %{consent_status: status})
    end
  end

  defp accepted!(room, user) do
    p =
      Repo.one(
        from(p in Participant,
          where: p.tenant_id == ^room.tenant_id and p.room_id == ^room.id and p.user_id == ^user,
          lock: "FOR UPDATE"
        )
      )

    if is_nil(p) or p.consent_status != "accepted" or p.withdrawn_at,
      do: Repo.rollback(:federation_consent_required)

    p
  end

  defp withdraw_user!(room, user) do
    p =
      Repo.one(
        from(p in Participant,
          where: p.tenant_id == ^room.tenant_id and p.room_id == ^room.id and p.user_id == ^user,
          lock: "FOR UPDATE"
        )
      )

    if p, do: withdraw_participant!(p)
  end

  defp withdraw_participant!(p) do
    unless p.withdrawn_at do
      update!(p, Participant, %{withdrawn_at: now(), consent_status: "withdrawn"})
      recover_uncertain_sends!(room_for_participant(p), p.user_id)

      Repo.update_all(
        from(c in Command,
          where:
            c.tenant_id == ^p.tenant_id and c.room_id == ^p.room_id and c.user_id == ^p.user_id and
              c.kind in ["create", "invite", "invite_local", "send"] and c.status != "done"
        ),
        set: [status: "cancelled", payload_box: nil, updated_at: now()]
      )

      room = Repo.get!(Room, p.room_id)
      if is_nil(room.provider_room_box), do: enqueue!(room, nil, "recover_room", %{}, false)
      {:ok, principal} = open!(p, :principal_box, "principal")
      enqueue!(room, nil, "leave", %{principal: principal}, false)
      redact_receipts!(room, p.user_id)
    end
  end

  defp fence_room!(room) do
    unless room.fenced_at do
      room =
        update!(room, Room, %{
          status: "fenced",
          fenced_at: now(),
          generation: room.generation + 1,
          remote_cleanup_state: "pending"
        })

      recover_uncertain_sends!(room, nil)

      Repo.update_all(
        from(c in Command,
          where:
            c.tenant_id == ^room.tenant_id and c.room_id == ^room.id and
              c.kind in ["create", "invite", "invite_local", "send"] and c.status != "done"
        ),
        set: [status: "cancelled", payload_box: nil, updated_at: now()]
      )

      if is_nil(room.provider_room_box), do: enqueue!(room, nil, "recover_room", %{}, false)
      redact_receipts!(room)

      Enum.each(participants!(room), fn p ->
        enqueue!(room, nil, "leave", %{principal: p.principal}, false)
      end)

      enqueue!(room, nil, "close", %{}, false)
    end
  end

  defp redact_receipts!(room, user_id \\ nil) do
    Repo.all(
      from(e in EventReceipt,
        where:
          e.tenant_id == ^room.tenant_id and e.room_id == ^room.id and
            is_nil(e.redacted_observed_at),
        order_by: e.id,
        lock: "FOR UPDATE"
      )
    )
    |> Enum.each(fn e ->
      command = if e.command_id, do: Repo.get(Command, e.command_id)

      principal_hash =
        if user_id,
          do:
            Repo.get_by(Participant,
              tenant_id: room.tenant_id,
              room_id: room.id,
              user_id: user_id
            ).principal_hash

      if (not is_nil(command) and (is_nil(user_id) or command.user_id == user_id)) or
           (not is_nil(principal_hash) and e.sender_hash == principal_hash) do
        {:ok, event} = open!(e, :provider_event_box, "event")
        enqueue!(room, nil, "redact", %{event_id: event, receipt_id: e.id}, false)
      end
    end)
  end

  defp enqueue_cleanup_or_invite!(room, p, principal, subject) do
    if p.consent_status == "accepted" and is_nil(p.withdrawn_at),
      do: enqueue!(room, subject, "invite_local", %{principal: principal}, true)
  end

  defp room_for_participant(p), do: Repo.get_by!(Room, id: p.room_id, tenant_id: p.tenant_id)

  defp recover_uncertain_sends!(room, user) do
    all_users = is_nil(user)
    users = if all_users, do: [], else: [user]

    Repo.all(
      from(c in Command,
        where:
          c.tenant_id == ^room.tenant_id and c.room_id == ^room.id and c.kind == "send" and
            c.status not in ["done", "cancelled"] and (^all_users or c.user_id in ^users),
        order_by: c.id
      )
    )
    |> Enum.each(fn c ->
      enqueue!(room, nil, "recover_send", %{source_transaction_id: c.id}, false)
    end)
  end

  defp enqueue!(room, grant, kind, payload, expires?, request_key \\ nil) do
    request_key = request_key || kind <> ":" <> SecretBox.hash(Jason.encode!(payload))
    digest = SecretBox.hash(Jason.encode!(payload))

    case Repo.get_by(Command,
           tenant_id: room.tenant_id,
           room_id: room.id,
           request_key: request_key
         ) do
      nil ->
        insert_command!(room, grant, kind, payload, expires?, request_key, digest)

      existing ->
        if existing.payload_digest != digest, do: Repo.rollback(:federation_idempotency_conflict)
        existing
    end
  end

  defp insert_command!(room, grant, kind, payload, expires?, request_key, digest) do
    id = Ecto.UUID.generate()

    command =
      Repo.insert!(
        Command.changeset(%Command{id: id}, %{
          tenant_id: room.tenant_id,
          room_id: room.id,
          user_id: if(grant, do: value(grant, :user_id)),
          device_id: if(grant, do: value(grant, :device_id)),
          session_id: if(grant, do: value(grant, :session_id)),
          kind: kind,
          request_key: request_key,
          payload_digest: digest,
          target_receipt_id: Map.get(payload, :receipt_id),
          payload_box: SecretBox.seal(room.tenant_id, id, "command", payload),
          generation: room.generation,
          expected_room_version: room.lock_version,
          expires_at: if(expires?, do: DateTime.add(now(), 300, :second))
        })
      )

    job =
      Oban.Job.new(%{command_id: command.id},
        worker: RuntimePorts.job_worker_name!(:federation_command),
        queue: :lifecycle,
        max_attempts: 12
      )

    case Oban.insert(job) do
      {:ok, _} -> command
      {:error, _} -> Repo.rollback(:federation_job_unavailable)
    end
  end

  defp receipt!(room, command, event, sender) do
    hash = SecretBox.hash(event)

    case Repo.get_by(EventReceipt, tenant_id: room.tenant_id, room_id: room.id, event_hash: hash) do
      nil ->
        bounded!(EventReceipt, room.tenant_id, 10_000)
        id = Ecto.UUID.generate()

        Repo.insert!(
          EventReceipt.changeset(%EventReceipt{id: id}, %{
            tenant_id: room.tenant_id,
            room_id: room.id,
            command_id: command,
            event_hash: hash,
            provider_event_box: SecretBox.seal(room.tenant_id, id, "event", event),
            sender_hash: SecretBox.hash(sender),
            observed_at: now()
          })
        )

      receipt ->
        receipt
    end
  end

  defp local_user_ids_for_conversation(_, nil, _), do: []

  defp local_user_ids_for_conversation(tenant, conversation, active?) do
    case Repo.get_by(Room, tenant_id: tenant, conversation_id: conversation) do
      nil -> []
      room -> local_user_ids(room, active?)
    end
  end

  defp local_user_ids(room, active?) do
    Repo.all(
      from(p in Participant,
        where:
          p.tenant_id == ^room.tenant_id and p.room_id == ^room.id and not is_nil(p.user_id) and
            (^(not active?) or is_nil(p.withdrawn_at)),
        order_by: p.user_id,
        select: p.user_id
      )
    )
    |> Enum.uniq()
  end

  defp participants!(room),
    do:
      Repo.all(
        from(p in Participant,
          where: p.tenant_id == ^room.tenant_id and p.room_id == ^room.id,
          order_by: p.id
        )
      )
      |> Enum.map(fn p ->
        %{record: p, principal: ok_value!(open!(p, :principal_box, "principal"))}
      end)

  defp cursor!(_, _, nil), do: nil

  defp cursor!(room, user, encoded) when is_binary(encoded) and byte_size(encoded) <= 4096 do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, box} -> ok_value!(SecretBox.open(room.tenant_id, room.id, "cursor:" <> user, box))
      _ -> Repo.rollback(:invalid_federation_cursor)
    end
  end

  defp cursor!(_, _, _), do: Repo.rollback(:invalid_federation_cursor)

  defp scope_rooms(tenant, :conversation, id),
    do:
      Repo.all(
        from(r in Room,
          where: r.tenant_id == ^tenant and r.conversation_id == ^id,
          order_by: r.id
        )
      )

  defp scope_rooms(tenant, :user, id),
    do:
      Repo.all(
        from(r in Room,
          join: p in Participant,
          on: p.room_id == r.id and p.tenant_id == r.tenant_id,
          where: r.tenant_id == ^tenant and p.user_id == ^id,
          distinct: true,
          order_by: r.id
        )
      )

  defp scope_rooms(_, _, _), do: []

  defp open!(row, field, purpose),
    do: SecretBox.open(row.tenant_id, row.id, purpose, Map.fetch!(row, field))

  defp provider!(r), do: ok_value!(CommsCore.Conversations.Federation.ProviderAdapter.perform(r))

  defp ids(repo, schema, tenant),
    do: repo.all(from(s in schema, where: s.tenant_id == ^tenant, select: s.id))

  defp trust_view(t),
    do: %{
      id: t.id,
      domain: t.domain,
      residency: t.residency,
      cross_border_reason: t.cross_border_reason,
      enabled: t.enabled,
      version: t.lock_version,
      residency_verified: false
    }

  defp view(room, user) do
    trust = Repo.get!(Trust, room.trust_id)

    participant =
      Repo.get_by(Participant, tenant_id: room.tenant_id, room_id: room.id, user_id: user)

    %View{
      id: room.id,
      conversation_id: room.conversation_id,
      domain: trust.domain,
      residency: trust.residency,
      status: room.status,
      version: room.lock_version,
      consent: if(participant, do: participant.consent_status, else: "none"),
      remote_cleanup_state: cleanup_state(room)
    }
  end

  defp cleanup_state(room) do
    if Repo.exists?(
         from(c in Command,
           where:
             c.tenant_id == ^room.tenant_id and c.room_id == ^room.id and
               c.kind in ["redact", "recover_room", "recover_send", "leave", "close"]
         )
       ),
       do:
         if(room.remote_cleanup_state == "none", do: "pending", else: room.remote_cleanup_state),
       else: room.remote_cleanup_state
  end

  defp active!(%{status: "active", fenced_at: nil}), do: :ok
  defp active!(_), do: Repo.rollback(:federation_room_unavailable)

  defp enabled!,
    do:
      if(Application.get_env(:comms_core, :federation_enabled, false),
        do: :ok,
        else: Repo.rollback(:federation_disabled)
      )

  defp unblocked!(p),
    do:
      if(p.held or p.capture_blocked,
        do: Repo.rollback(:federation_governance_blocked),
        else: :ok
      )

  defp human!(%AccessGrant{account_type: :human, access_scope: :workspace}), do: :ok
  defp human!(_), do: Repo.rollback(:forbidden)

  defp admin(
         %AccessGrant{account_type: :human, access_scope: :workspace, role: role} = grant,
         step?
       )
       when role in [:owner, :admin],
       do: if(step? and not grant.step_up_recent?, do: {:error, :step_up_required}, else: :ok)

  defp admin(_, _), do: {:error, :forbidden}

  defp version!(row, attrs),
    do:
      if(value(attrs, :version) == row.lock_version, do: :ok, else: Repo.rollback(:stale_version))

  defp bounded!(schema, tenant, max),
    do:
      if(Repo.aggregate(from(s in schema, where: s.tenant_id == ^tenant), :count) >= max,
        do: Repo.rollback(:federation_quota),
        else: :ok
      )

  defp bounded_room!(schema, room, max),
    do:
      if(
        Repo.aggregate(
          from(s in schema, where: s.tenant_id == ^room.tenant_id and s.room_id == ^room.id),
          :count
        ) >= max,
        do: Repo.rollback(:federation_quota),
        else: :ok
      )

  defp bounded_pending!(room),
    do:
      if(
        Repo.aggregate(
          from(c in Command,
            where:
              c.tenant_id == ^room.tenant_id and c.room_id == ^room.id and
                c.status in ["pending", "prepared", "uncertain"]
          ),
          :count
        ) >= 50,
        do: Repo.rollback(:federation_quota),
        else: :ok
      )

  defp insert!(Trust, attrs), do: Trust.changeset(%Trust{}, attrs) |> Repo.insert!()

  defp update!(%Trust{} = row, Trust, attrs),
    do:
      row
      |> Trust.changeset(attrs)
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> Repo.update!()

  defp update!(%Room{} = row, Room, attrs),
    do:
      row
      |> Room.changeset(attrs)
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> Repo.update!()

  defp update!(%Participant{} = row, Participant, attrs),
    do:
      row
      |> Participant.changeset(attrs)
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> Repo.update!()

  defp text(value, min, max) when is_binary(value) do
    trimmed = String.trim(value)

    if byte_size(trimmed) in min..max,
      do: {:ok, trimmed},
      else: {:error, :invalid_federation_text}
  end

  defp text(_, _, _), do: {:error, :invalid_federation_text}
  defp operation("create"), do: :create
  defp operation("send"), do: :send
  defp operation(kind) when kind in ["invite", "invite_local"], do: :invite
  defp operation("recover_room"), do: :create
  defp operation("recover_send"), do: :recover_event
  defp operation("redact"), do: :redact
  defp operation("leave"), do: :leave
  defp operation("close"), do: :close
  defp ok!(:ok), do: :ok
  defp ok!({:ok, _}), do: :ok
  defp ok!({:error, reason}), do: Repo.rollback(reason)
  defp ok_value!({:ok, value}), do: value
  defp ok_value!({:error, reason}), do: Repo.rollback(reason)

  defp budget! do
    remaining = deadline() - System.monotonic_time(:millisecond)
    if remaining <= 0, do: Repo.rollback(:federation_deadline)
    timeout = Integer.to_string(remaining) <> "ms"

    Repo.query!(
      "SELECT set_config('lock_timeout', $1, true), set_config('statement_timeout', $1, true)",
      [timeout]
    )

    :ok
  end

  defp deadline, do: Process.get({__MODULE__, :deadline})
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
