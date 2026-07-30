defmodule CommsCore.Conversations.EphemeralRooms do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{
    Accounts,
    Administration,
    AdmissionQuotas,
    Repo,
    RuntimePorts
  }

  alias CommsCore.Conversations.{
    CallLifecycleCommand,
    CallLifecyclePort,
    CallLifecycleReceipt,
    Conversation,
    EphemeralPresenceLease,
    EphemeralJoinReceipt,
    EphemeralReplayBox,
    EphemeralRoom,
    EphemeralRoomView,
    GuestAdmission,
    GuestLink,
    Membership
  }

  alias CommsCore.Conversations.EphemeralRooms.{
    Events,
    Maintenance,
    Projection,
    Request,
    Scheduler
  }

  @authority_horizon_seconds 24 * 60 * 60
  @authority_refresh_seconds 12 * 60 * 60
  @idempotency_window_seconds 10 * 60
  @global_reconcile_limit 100
  @max_active_leases_per_user 5

  @spec create(map(), :guest | map()) :: {:ok, map()} | {:error, term()}
  def create(attrs, creator) when is_map(attrs) and (creator == :guest or is_map(creator)) do
    with {:ok, idempotency_secret} <- exact_secret(value(attrs, :idempotency_key)),
         {:ok, creator_scope} <- creator_scope(attrs, creator),
         {:ok, title} <- room_title(value(attrs, :title)),
         {:ok, display_name} <- creator_display_name(attrs, creator_scope),
         {:ok, device} <- creator_device(attrs, creator_scope) do
      idempotency_digest = digest(idempotency_secret)

      request_fingerprint =
        create_fingerprint(creator_scope, title, display_name, device)

      case replay_creation(
             creator_scope,
             idempotency_digest,
             request_fingerprint,
             device
           ) do
        {:ok, result} ->
          {:ok, result}

        :not_found ->
          create_new_room(
            attrs,
            creator_scope,
            title,
            display_name,
            device,
            idempotency_digest,
            request_fingerprint
          )
          |> recover_creation_race(
            creator_scope,
            idempotency_digest,
            request_fingerprint,
            device
          )

        {:error, _reason} = error ->
          error
      end
    end
  end

  def create(_attrs, _creator), do: {:error, :forbidden}

  @spec preview(String.t()) ::
          {:ok,
           %{
             room_id: Ecto.UUID.t(),
             room_title: String.t(),
             status: :active | :idle,
             expires_at: DateTime.t() | nil,
             participant_limit: pos_integer()
           }}
          | {:error, :ephemeral_room_unavailable}
  def preview(token) when is_binary(token) do
    with :ok <- instant_rooms_enabled(),
         {:ok, token_secret} <- exact_token(token),
         %GuestLink{purpose: :ephemeral_room} = link <-
           Repo.get_by(GuestLink, token_digest: digest(token_secret)),
         %EphemeralRoom{} = room <-
           Repo.get_by(EphemeralRoom,
             tenant_id: link.tenant_id,
             conversation_id: link.conversation_id,
             guest_link_id: link.id
           ),
         %Conversation{} = conversation <-
           Repo.get_by(Conversation,
             id: room.conversation_id,
             tenant_id: room.tenant_id
           ),
         :ok <- available_room(room, link, conversation, now()),
         {:ok, _tenant} <- Administration.active_tenant(room.tenant_id) do
      {:ok,
       %{
         room_id: room.id,
         room_title: title_for(conversation),
         status: room.status,
         expires_at: room.expires_at,
         participant_limit: room.participant_limit
       }}
    else
      _ -> {:error, :ephemeral_room_unavailable}
    end
  end

  def preview(_token), do: {:error, :ephemeral_room_unavailable}

  @spec join(String.t(), map(), :guest | map()) :: {:ok, map()} | {:error, term()}
  def join(token, attrs, joiner)
      when is_binary(token) and is_map(attrs) and (joiner == :guest or is_map(joiner)) do
    with :ok <- instant_rooms_enabled(),
         {:ok, token_secret} <- exact_token(token),
         {:ok, idempotency_secret} <- exact_secret(value(attrs, :idempotency_key)),
         %GuestLink{purpose: :ephemeral_room} = link_snapshot <-
           Repo.get_by(GuestLink, token_digest: digest(token_secret)),
         {:ok, joiner_scope} <- joiner_scope(joiner, link_snapshot),
         {:ok, display_name} <- join_display_name(attrs, joiner_scope),
         {:ok, device} <- join_device(attrs, joiner_scope) do
      idempotency_digest = digest(idempotency_secret)

      request_fingerprint =
        join_fingerprint(link_snapshot, joiner_scope, display_name, device)

      do_join(
        link_snapshot,
        token_secret,
        attrs,
        joiner_scope,
        display_name,
        device,
        idempotency_digest,
        request_fingerprint
      )
      |> recover_join_race(
        link_snapshot,
        token_secret,
        attrs,
        joiner_scope,
        display_name,
        device,
        idempotency_digest,
        request_fingerprint
      )
    else
      {:error, reason}
      when reason in [
             :invalid_idempotency_key,
             :invalid_guest_display_name,
             :invalid_guest_device
           ] ->
        {:error, reason}

      _ ->
        {:error, :ephemeral_room_unavailable}
    end
  end

  def join(_token, _attrs, _joiner), do: {:error, :ephemeral_room_unavailable}

  @spec open_presence(map()) :: {:ok, map()} | {:error, term()}
  def open_presence(attrs) when is_map(attrs),
    do: upsert_presence(attrs, :open)

  def open_presence(_attrs), do: {:error, :forbidden}

  @spec heartbeat_presence(map()) :: {:ok, map()} | {:error, term()}
  def heartbeat_presence(attrs) when is_map(attrs),
    do: upsert_presence(attrs, :heartbeat)

  def heartbeat_presence(_attrs), do: {:error, :forbidden}

  @spec close_presence(map()) :: {:ok, map()} | {:error, term()}
  def close_presence(attrs) when is_map(attrs) do
    with {:ok, grant} <- Accounts.access_grant(attrs),
         {:ok, conversation_id} <- cast_uuid(value(attrs, :conversation_id)),
         {:ok, connection_secret} <- exact_secret(value(attrs, :connection_id)),
         %EphemeralRoom{} = snapshot <-
           Repo.get_by(EphemeralRoom,
             tenant_id: grant.tenant_id,
             conversation_id: conversation_id
           ) do
      Repo.transaction(fn ->
        _policy = admission_policy!(snapshot.tenant_id)
        {_conversation, _link, room} = lock_room_scope!(snapshot)
        authorize_presence!(room, grant)

        lease =
          Repo.one(
            from(lease in EphemeralPresenceLease,
              where:
                lease.ephemeral_room_id == ^room.id and
                  lease.connection_digest == ^digest(connection_secret) and
                  lease.user_id == ^grant.user_id and lease.session_id == ^grant.session_id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:ephemeral_presence_not_found)

        timestamp = now()

        closed =
          if lease.closed_at do
            lease
          else
            lease
            |> EphemeralPresenceLease.changeset(%{
              last_seen_at: timestamp,
              expires_at: DateTime.add(timestamp, 1, :second),
              closed_at: timestamp
            })
            |> Ecto.Changeset.optimistic_lock(:lock_version)
            |> update_or_rollback()
          end

        disconnect_at = closed.closed_at || timestamp
        updated_room = advance_last_presence!(room, disconnect_at)
        reconcile_at = DateTime.add(disconnect_at, updated_room.reconnect_grace_seconds, :second)
        Scheduler.enqueue_reconcile!(updated_room, reconcile_at)

        %{
          room: Projection.room(updated_room),
          generation: updated_room.generation,
          reconcile_at: reconcile_at,
          lease_id: closed.id
        }
      end)
      |> transaction_result()
    else
      _ -> {:error, :forbidden}
    end
  end

  def close_presence(_attrs), do: {:error, :forbidden}

  @spec room_for_conversation(Ecto.UUID.t(), map()) ::
          {:ok, EphemeralRoomView.t() | nil} | {:error, :forbidden}
  def room_for_conversation(conversation_id, subject)
      when is_binary(conversation_id) and is_map(subject) do
    with {:ok, grant} <- Accounts.access_grant(subject),
         {:ok, conversation_id} <- cast_uuid(conversation_id),
         true <- active_membership?(grant.tenant_id, conversation_id, grant.user_id) do
      case Repo.get_by(EphemeralRoom,
             tenant_id: grant.tenant_id,
             conversation_id: conversation_id
           ) do
        nil -> {:ok, nil}
        room -> {:ok, Projection.room(room)}
      end
    else
      _ -> {:error, :forbidden}
    end
  end

  def room_for_conversation(_conversation_id, _subject), do: {:error, :forbidden}

  @spec reconcile(Ecto.UUID.t(), pos_integer(), module()) ::
          {:ok,
           :active
           | :already_terminal
           | :stale_generation
           | {:idle, DateTime.t(), pos_integer()}}
          | {:error, term()}
  def reconcile(room_id, expected_generation, caller)
      when is_binary(room_id) and is_integer(expected_generation) and expected_generation > 0 do
    if RuntimePorts.authorized_job_worker?(:ephemeral_room_reconciler, caller) do
      with {:ok, room_id} <- cast_uuid(room_id),
           %EphemeralRoom{} = snapshot <- Repo.get(EphemeralRoom, room_id) do
        Repo.transaction(fn ->
          _policy = admission_policy!(snapshot.tenant_id)
          {_conversation, link, room} = lock_room_scope!(snapshot)

          cond do
            room.status == :expired ->
              :already_terminal

            room.generation != expected_generation ->
              :stale_generation

            live_presence?(room.id, now()) ->
              :active

            within_reconnect_grace?(room, now()) ->
              :active

            room.status == :idle ->
              Scheduler.enqueue_expiry!(room, room.expires_at)
              {:idle, room.expires_at, room.generation}

            true ->
              transition_to_idle!(room, link)
          end
        end)
        |> transaction_result()
      else
        _ -> {:error, :ephemeral_room_not_found}
      end
    else
      {:error, :forbidden}
    end
  end

  def reconcile(_room_id, _expected_generation, _caller), do: {:error, :forbidden}

  @spec reconcile_all(module()) ::
          {:ok, %{scanned: non_neg_integer(), reconciled: non_neg_integer()}}
          | {:error, :forbidden}
  def reconcile_all(caller) do
    if RuntimePorts.authorized_job_worker?(:ephemeral_room_reconciler, caller) do
      scrubbed = Maintenance.scrub_expired_replay_capsules()
      leases_pruned = Maintenance.prune_terminal_presence_leases()
      join_receipts_pruned = Maintenance.prune_expired_join_receipts()

      candidates =
        Repo.all(
          from(room in EphemeralRoom,
            where: room.status in [:active, :idle],
            order_by: [asc: room.updated_at, asc: room.id],
            limit: @global_reconcile_limit,
            select: {room.id, room.generation}
          )
        )

      reconciled =
        Enum.count(candidates, fn {room_id, generation} ->
          match?({:ok, {:idle, _, _}}, reconcile(room_id, generation, caller))
        end)

      {:ok,
       %{
         scanned: length(candidates),
         reconciled: reconciled,
         scrubbed: scrubbed,
         leases_pruned: leases_pruned,
         join_receipts_pruned: join_receipts_pruned
       }}
    else
      {:error, :forbidden}
    end
  end

  @spec expire(Ecto.UUID.t(), pos_integer(), module(), function()) ::
          {:ok,
           :expired | :already_terminal | :active | :stale_generation | {:not_due, pos_integer()}}
          | {:error, term()}
  def expire(room_id, expected_generation, caller, call_access_revoker)
      when is_binary(room_id) and is_integer(expected_generation) and expected_generation > 0 and
             is_function(call_access_revoker, 4) do
    if RuntimePorts.authorized_job_worker?(:ephemeral_room_lifecycle, caller) do
      with {:ok, room_id} <- cast_uuid(room_id),
           %EphemeralRoom{} = snapshot <- Repo.get(EphemeralRoom, room_id) do
        Repo.transaction(fn ->
          _policy = admission_policy!(snapshot.tenant_id)
          {conversation, link, room} = lock_room_scope!(snapshot)
          timestamp = now()

          cond do
            room.status == :expired ->
              :already_terminal

            room.generation != expected_generation ->
              :stale_generation

            room.status == :active or live_presence?(room.id, timestamp) ->
              :active

            DateTime.compare(room.expires_at, timestamp) == :gt ->
              {:not_due, max(DateTime.diff(room.expires_at, timestamp, :second), 1)}

            true ->
              expire_locked!(conversation, link, room, timestamp, call_access_revoker)
          end
        end)
        |> transaction_result()
      else
        _ -> {:error, :ephemeral_room_not_found}
      end
    else
      {:error, :forbidden}
    end
  end

  def expire(_room_id, _expected_generation, _caller, _call_access_revoker),
    do: {:error, :forbidden}

  def persisted_room_count, do: Repo.aggregate(EphemeralRoom, :count)
  def persisted_presence_lease_count, do: Repo.aggregate(EphemeralPresenceLease, :count)
  def persisted_join_receipt_count, do: Repo.aggregate(EphemeralJoinReceipt, :count)

  @doc false
  def lock_conversion_room(%GuestLink{purpose: :ephemeral_room} = link) do
    Repo.one(
      from(room in EphemeralRoom,
        where:
          room.tenant_id == ^link.tenant_id and room.conversation_id == ^link.conversation_id and
            room.guest_link_id == ^link.id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:forbidden)
  end

  def lock_conversion_room(%GuestLink{}), do: nil

  @doc false
  def upgrade_converted_owner(nil, _authentication, _timestamp, _request_id), do: false

  def upgrade_converted_owner(%EphemeralRoom{} = room, authentication, timestamp, request_id) do
    if room.creator_user_id == authentication.user.id and room.owner_kind == :guest do
      expires_at =
        if room.status == :idle do
          DateTime.add(room.idle_since, registered_idle_ttl(), :second)
        else
          nil
        end

      updated =
        room
        |> EphemeralRoom.changeset(%{
          owner_kind: :registered,
          creator_session_id: authentication.session_id,
          idle_ttl_seconds: registered_idle_ttl(),
          expires_at: expires_at,
          generation: room.generation + 1
        })
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> update_or_rollback()

      updated =
        if updated.status == :idle do
          link = Repo.get!(GuestLink, updated.guest_link_id)
          extend_link_and_admissions!(updated, link, updated.expires_at)
        else
          updated
        end

      if updated.status == :idle do
        Scheduler.enqueue_expiry!(updated, updated.expires_at)
      else
        Scheduler.enqueue_reconcile!(
          updated,
          DateTime.add(timestamp, updated.reconnect_grace_seconds, :second)
        )
      end

      Events.emit!(
        updated,
        "ephemeral_room.owner_upgraded.v1",
        updated.creator_user_id,
        %{owner_kind: "registered", generation: updated.generation},
        request_id
      )

      true
    else
      false
    end
  end

  @doc false
  def handoff_converted_presence(
        nil,
        _old_session_id,
        _authentication,
        _timestamp
      ),
      do: 0

  def handoff_converted_presence(
        %EphemeralRoom{} = room,
        old_session_id,
        %{user: %{id: user_id}, session_id: new_session_id},
        %DateTime{} = timestamp
      )
      when is_binary(old_session_id) and is_binary(user_id) and is_binary(new_session_id) do
    {count, _} =
      Repo.update_all(
        from(lease in EphemeralPresenceLease,
          where:
            lease.ephemeral_room_id == ^room.id and lease.user_id == ^user_id and
              lease.session_id == ^old_session_id,
          update: [
            set: [
              session_id: ^new_session_id,
              closed_at: fragment("COALESCE(?, ?)", lease.closed_at, ^timestamp),
              updated_at: ^timestamp
            ]
          ]
        ),
        []
      )

    if count > 0 do
      current = Repo.get!(EphemeralRoom, room.id)

      Scheduler.enqueue_reconcile!(
        current,
        DateTime.add(timestamp, current.reconnect_grace_seconds, :second)
      )
    end

    count
  end

  @doc false
  def close_logged_out_presence(
        nil,
        _user_id,
        _session_id,
        _timestamp
      ),
      do: 0

  def close_logged_out_presence(
        %EphemeralRoom{} = room,
        user_id,
        session_id,
        %DateTime{} = timestamp
      )
      when is_binary(user_id) and is_binary(session_id) do
    {count, _} =
      Repo.update_all(
        from(lease in EphemeralPresenceLease,
          where:
            lease.ephemeral_room_id == ^room.id and lease.user_id == ^user_id and
              lease.session_id == ^session_id and is_nil(lease.closed_at)
        ),
        set: [closed_at: timestamp, updated_at: timestamp]
      )

    if count > 0 and room.status == :active do
      Scheduler.enqueue_reconcile!(
        room,
        DateTime.add(timestamp, room.reconnect_grace_seconds, :second)
      )
    end

    count
  end

  defp create_new_room(
         attrs,
         creator_scope,
         title,
         display_name,
         device,
         idempotency_digest,
         request_fingerprint
       ) do
    room_id = Ecto.UUID.generate()
    {token_secret, token} = Request.generate_token()

    with {:ok, replay_material} <-
           EphemeralReplayBox.encrypt(token, creator_scope.tenant_id, room_id) do
      Repo.transaction(fn ->
        timestamp = now()
        authority_expires_at = DateTime.add(timestamp, @authority_horizon_seconds, :second)
        idempotency_expires_at = DateTime.add(timestamp, @idempotency_window_seconds, :second)
        policy = admission_policy!(creator_scope.tenant_id)

        participant_limit =
          min(instant_room_max_participants(), policy.max_conversation_members)

        quota_ok!(
          AdmissionQuotas.check_conversation_creation(
            policy,
            active_conversation_count(creator_scope.tenant_id),
            1
          )
        )

        {authentication, creator_user_id, creator_session_id, actor_user_id} =
          provision_creator!(
            attrs,
            creator_scope,
            display_name,
            device,
            authority_expires_at
          )

        conversation =
          %Conversation{}
          |> Conversation.changeset(%{
            tenant_id: creator_scope.tenant_id,
            created_by_user_id: creator_user_id,
            kind: :group,
            title: title,
            visibility: :private,
            next_sequence: 1
          })
          |> insert_or_rollback()

        membership =
          %Membership{}
          |> Membership.changeset(%{
            tenant_id: creator_scope.tenant_id,
            conversation_id: conversation.id,
            user_id: creator_user_id,
            role: :owner,
            joined_at: timestamp,
            last_read_sequence: 0
          })
          |> insert_or_rollback()

        link =
          %GuestLink{}
          |> GuestLink.changeset(%{
            tenant_id: creator_scope.tenant_id,
            conversation_id: conversation.id,
            created_by_user_id: creator_user_id,
            purpose: :ephemeral_room,
            token_digest: digest(token_secret),
            expires_at: authority_expires_at,
            max_uses: participant_limit,
            use_count: 0
          })
          |> insert_or_rollback()

        room =
          %EphemeralRoom{id: room_id}
          |> EphemeralRoom.changeset(%{
            tenant_id: creator_scope.tenant_id,
            conversation_id: conversation.id,
            guest_link_id: link.id,
            creator_user_id: creator_user_id,
            creator_session_id: creator_session_id,
            owner_kind: creator_scope.owner_kind,
            status: :active,
            idempotency_digest: idempotency_digest,
            request_fingerprint: request_fingerprint,
            replay_ciphertext: replay_material.ciphertext,
            replay_nonce: replay_material.nonce,
            replay_tag: replay_material.tag,
            replay_key_id: replay_material.key_id,
            idempotency_expires_at: idempotency_expires_at,
            generation: 1,
            participant_limit: participant_limit,
            reconnect_grace_seconds: reconnect_grace(),
            idle_ttl_seconds: idle_ttl(creator_scope.owner_kind),
            authority_expires_at: authority_expires_at
          })
          |> insert_or_rollback()

        admission =
          maybe_create_creator_admission!(
            creator_scope,
            authentication,
            conversation,
            membership,
            link,
            timestamp,
            authority_expires_at
          )

        Scheduler.enqueue_reconcile!(
          room,
          DateTime.add(timestamp, room.reconnect_grace_seconds, :second)
        )

        Events.emit!(
          room,
          "ephemeral_room.created.v1",
          actor_user_id,
          %{
            conversation_id: conversation.id,
            owner_kind: Atom.to_string(room.owner_kind),
            participant_limit: room.participant_limit
          },
          value(attrs, :request_id)
        )

        response(
          room,
          conversation,
          token,
          authentication,
          admission,
          membership,
          false
        )
      end)
      |> transaction_result()
    end
  end

  defp replay_creation(
         creator_scope,
         idempotency_digest,
         request_fingerprint,
         device
       ) do
    case Repo.get_by(EphemeralRoom,
           tenant_id: creator_scope.tenant_id,
           idempotency_digest: idempotency_digest
         ) do
      nil ->
        :not_found

      snapshot ->
        Repo.transaction(fn ->
          {_conversation, _link, room} = lock_room_scope!(snapshot)
          replay_creation_locked!(room, creator_scope, request_fingerprint, device)
        end)
        |> transaction_result()
    end
  end

  defp replay_creation_locked!(room, creator_scope, request_fingerprint, device) do
    timestamp = now()

    if not secure_match?(room.request_fingerprint, request_fingerprint),
      do: Repo.rollback(:idempotency_conflict)

    if DateTime.compare(room.idempotency_expires_at, timestamp) != :gt,
      do: Repo.rollback(:idempotency_replay_expired)

    token =
      case EphemeralReplayBox.decrypt(room) do
        {:ok, token} -> token
        {:error, reason} -> Repo.rollback(reason)
      end

    conversation = Repo.get!(Conversation, room.conversation_id)

    membership =
      Repo.get_by!(Membership,
        conversation_id: room.conversation_id,
        user_id: room.creator_user_id
      )

    {authentication, admission, room} =
      if creator_scope.owner_kind == :guest do
        replay_guest_creator!(room, device)
      else
        {nil, nil, room}
      end

    response(room, conversation, token, authentication, admission, membership, true)
  end

  defp replay_guest_creator!(room, device) do
    admission =
      Repo.one(
        from(admission in GuestAdmission,
          where:
            admission.tenant_id == ^room.tenant_id and
              admission.conversation_id == ^room.conversation_id and
              admission.guest_user_id == ^room.creator_user_id and
              is_nil(admission.revoked_at) and is_nil(admission.converted_at),
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:idempotency_replay_unavailable)

    {deadline, room} = ensure_rolling_authority!(room, false)

    authentication =
      case Accounts.resume_ephemeral_guest_identity(%{
             user_id: room.creator_user_id,
             session_id: admission.session_id,
             expires_at: deadline,
             device: device,
             guest_authority_purpose: :ephemeral_room
           }) do
        {:ok, authentication} -> authentication
        {:error, reason} -> Repo.rollback(reason)
      end

    updated_admission =
      admission
      |> GuestAdmission.changeset(%{
        session_id: authentication.session_id,
        expires_at: deadline
      })
      |> update_or_rollback()

    updated_room =
      room
      |> EphemeralRoom.changeset(%{
        creator_session_id: authentication.session_id,
        authority_expires_at: deadline
      })
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> update_or_rollback()

    {authentication, updated_admission, updated_room}
  end

  defp recover_creation_race(
         {:error, %Ecto.Changeset{}},
         creator_scope,
         idempotency_digest,
         request_fingerprint,
         device
       ) do
    case replay_creation(creator_scope, idempotency_digest, request_fingerprint, device) do
      :not_found -> {:error, :ephemeral_room_creation_failed}
      result -> result
    end
  end

  defp recover_creation_race(
         result,
         _creator_scope,
         _idempotency_digest,
         _request_fingerprint,
         _device
       ),
       do: result

  defp do_join(
         link_snapshot,
         token_secret,
         attrs,
         joiner_scope,
         display_name,
         device,
         idempotency_digest,
         request_fingerprint
       ) do
    Repo.transaction(fn ->
      _policy = admission_policy!(link_snapshot.tenant_id)

      {conversation, link, room} =
        lock_room_scope_by_link!(link_snapshot, token_secret)

      timestamp = now()
      available_room!(room, link, conversation, timestamp)
      room = reactivate_room!(room, link, value(attrs, :request_id))

      case joiner_scope.account_type do
        :guest ->
          join_guest!(
            room,
            conversation,
            link,
            attrs,
            display_name,
            device,
            idempotency_digest,
            request_fingerprint
          )

        :human ->
          join_human!(
            room,
            conversation,
            link,
            attrs,
            joiner_scope,
            idempotency_digest,
            request_fingerprint
          )
      end
    end)
    |> transaction_result()
  end

  defp join_guest!(
         room,
         conversation,
         link,
         attrs,
         display_name,
         device,
         idempotency_digest,
         request_fingerprint
       ) do
    case lock_join_admission(link.id, idempotency_digest) do
      %GuestAdmission{} = admission ->
        replay_guest_join!(
          room,
          conversation,
          admission,
          request_fingerprint,
          device
        )

      nil ->
        quota_ok!(ensure_member_capacity(room, conversation))
        {deadline, room} = ensure_rolling_authority!(room, false)
        admitted_at = now()
        idempotency_expires_at = DateTime.add(admitted_at, @idempotency_window_seconds, :second)

        authentication =
          case Accounts.provision_guest_identity(%{
                 tenant_id: room.tenant_id,
                 display_name: display_name,
                 device: device,
                 expires_at: deadline,
                 request_id: value(attrs, :request_id)
               }) do
            {:ok, result} -> result
            {:error, reason} -> Repo.rollback(reason)
          end

        membership =
          %Membership{}
          |> Membership.changeset(%{
            tenant_id: room.tenant_id,
            conversation_id: room.conversation_id,
            user_id: authentication.user.id,
            role: :member,
            joined_at: now(),
            last_read_sequence: max(conversation.next_sequence - 1, 0)
          })
          |> insert_or_rollback()

        admission =
          %GuestAdmission{}
          |> GuestAdmission.changeset(%{
            tenant_id: room.tenant_id,
            conversation_id: room.conversation_id,
            guest_link_id: link.id,
            guest_user_id: authentication.user.id,
            membership_id: membership.id,
            session_id: authentication.session_id,
            admitted_at: admitted_at,
            expires_at: deadline,
            history_from_sequence: conversation.next_sequence,
            join_idempotency_digest: idempotency_digest,
            request_fingerprint: request_fingerprint,
            idempotency_expires_at: idempotency_expires_at
          })
          |> insert_or_rollback()

        Scheduler.enqueue_guest_admission_expiry!(admission)

        join_response(
          room,
          conversation,
          nil,
          authentication,
          admission,
          membership,
          false,
          true
        )
    end
  end

  defp replay_guest_join!(room, conversation, admission, request_fingerprint, device) do
    if not secure_match?(admission.request_fingerprint, request_fingerprint),
      do: Repo.rollback(:idempotency_conflict)

    if DateTime.compare(admission.idempotency_expires_at, now()) != :gt,
      do: Repo.rollback(:idempotency_replay_expired)

    membership = Repo.get!(Membership, admission.membership_id)
    {deadline, room} = ensure_rolling_authority!(room, false)

    authentication =
      case Accounts.resume_ephemeral_guest_identity(%{
             user_id: admission.guest_user_id,
             session_id: admission.session_id,
             expires_at: deadline,
             device: device,
             guest_authority_purpose: :ephemeral_room
           }) do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end

    updated =
      admission
      |> GuestAdmission.changeset(%{
        session_id: authentication.session_id,
        expires_at: deadline
      })
      |> update_or_rollback()

    join_response(room, conversation, nil, authentication, updated, membership, true, false)
  end

  defp join_human!(
         room,
         conversation,
         _link,
         _attrs,
         joiner_scope,
         idempotency_digest,
         request_fingerprint
       ) do
    case lock_human_join_receipt(room.id, idempotency_digest) do
      %EphemeralJoinReceipt{} = receipt ->
        if not secure_match?(receipt.request_fingerprint, request_fingerprint),
          do: Repo.rollback(:idempotency_conflict)

        if DateTime.compare(receipt.expires_at, now()) != :gt,
          do: Repo.rollback(:idempotency_replay_expired)

        membership =
          Repo.one(
            from(membership in Membership,
              where:
                membership.id == ^receipt.membership_id and
                  membership.tenant_id == ^room.tenant_id and
                  membership.conversation_id == ^room.conversation_id and
                  membership.user_id == ^joiner_scope.user_id and is_nil(membership.left_at),
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:forbidden)

        join_response(room, conversation, nil, nil, nil, membership, true, false)

      nil ->
        membership =
          Repo.one(
            from(membership in Membership,
              where:
                membership.tenant_id == ^room.tenant_id and
                  membership.conversation_id == ^room.conversation_id and
                  membership.user_id == ^joiner_scope.user_id,
              lock: "FOR UPDATE"
            )
          )

        {membership, membership_changed} =
          case membership do
            %Membership{left_at: nil} = current ->
              {current, false}

            %Membership{} = departed
            when joiner_scope.access_scope in [:workspace, :conversation_only] ->
              quota_ok!(ensure_member_capacity(room, conversation))

              reactivated =
                departed
                |> Membership.changeset(%{
                  role: :member,
                  joined_at: now(),
                  left_at: nil
                })
                |> Ecto.Changeset.optimistic_lock(:lock_version)
                |> update_or_rollback()

              {reactivated, true}

            nil when joiner_scope.access_scope in [:workspace, :conversation_only] ->
              quota_ok!(ensure_member_capacity(room, conversation))

              inserted =
                %Membership{}
                |> Membership.changeset(%{
                  tenant_id: room.tenant_id,
                  conversation_id: room.conversation_id,
                  user_id: joiner_scope.user_id,
                  role: :member,
                  joined_at: now(),
                  last_read_sequence: max(conversation.next_sequence - 1, 0)
                })
                |> insert_or_rollback()

              {inserted, true}

            _ ->
              Repo.rollback(:forbidden)
          end

        timestamp = now()

        %EphemeralJoinReceipt{}
        |> EphemeralJoinReceipt.changeset(%{
          tenant_id: room.tenant_id,
          ephemeral_room_id: room.id,
          conversation_id: room.conversation_id,
          user_id: joiner_scope.user_id,
          membership_id: membership.id,
          idempotency_digest: idempotency_digest,
          request_fingerprint: request_fingerprint,
          expires_at: DateTime.add(timestamp, @idempotency_window_seconds, :second)
        })
        |> insert_or_rollback()

        join_response(
          room,
          conversation,
          nil,
          nil,
          nil,
          membership,
          false,
          membership_changed
        )
    end
  end

  defp recover_join_race(
         {:error, %Ecto.Changeset{}},
         link_snapshot,
         token_secret,
         attrs,
         joiner_scope,
         display_name,
         device,
         idempotency_digest,
         request_fingerprint
       ) do
    do_join(
      link_snapshot,
      token_secret,
      attrs,
      joiner_scope,
      display_name,
      device,
      idempotency_digest,
      request_fingerprint
    )
  end

  defp recover_join_race(
         result,
         _link_snapshot,
         _token_secret,
         _attrs,
         _joiner_scope,
         _display_name,
         _device,
         _idempotency_digest,
         _request_fingerprint
       ),
       do: result

  defp upsert_presence(attrs, mode) when mode in [:open, :heartbeat] do
    with {:ok, grant} <- Accounts.access_grant(attrs),
         {:ok, conversation_id} <- cast_uuid(value(attrs, :conversation_id)),
         {:ok, connection_secret} <- exact_secret(value(attrs, :connection_id)),
         %EphemeralRoom{} = snapshot <-
           Repo.get_by(EphemeralRoom,
             tenant_id: grant.tenant_id,
             conversation_id: conversation_id
           ) do
      Repo.transaction(fn ->
        _policy = admission_policy!(snapshot.tenant_id)
        {conversation, link, room} = lock_room_scope!(snapshot)
        timestamp = now()
        available_room!(room, link, conversation, timestamp)
        authorize_presence!(room, grant)
        room = reactivate_room!(room, link, value(attrs, :request_id))
        {deadline, room} = ensure_rolling_authority!(room, false)
        maybe_extend_present_guest!(room, grant, deadline)

        digest = digest(connection_secret)
        expires_at = DateTime.add(timestamp, presence_lease_seconds(), :second)

        current =
          Repo.one(
            from(lease in EphemeralPresenceLease,
              where: lease.ephemeral_room_id == ^room.id and lease.connection_digest == ^digest,
              lock: "FOR UPDATE"
            )
          )

        lease =
          case {mode, current} do
            {:heartbeat, nil} ->
              Repo.rollback(:ephemeral_presence_not_found)

            {:open, nil} ->
              enforce_presence_lease_limit!(room.id, grant.user_id, timestamp)

              %EphemeralPresenceLease{}
              |> EphemeralPresenceLease.changeset(%{
                tenant_id: room.tenant_id,
                ephemeral_room_id: room.id,
                conversation_id: room.conversation_id,
                user_id: grant.user_id,
                session_id: grant.session_id,
                connection_digest: digest,
                opened_at: timestamp,
                last_seen_at: timestamp,
                expires_at: expires_at
              })
              |> insert_or_rollback()

            {_mode, %EphemeralPresenceLease{} = lease}
            when lease.user_id == grant.user_id and lease.session_id == grant.session_id ->
              lease
              |> EphemeralPresenceLease.changeset(%{
                last_seen_at: timestamp,
                expires_at: expires_at,
                closed_at: nil
              })
              |> Ecto.Changeset.optimistic_lock(:lock_version)
              |> update_or_rollback()

            _ ->
              Repo.rollback(:forbidden)
          end

        updated_room =
          room
          |> EphemeralRoom.changeset(%{last_presence_at: timestamp})
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        %{
          room: Projection.room(updated_room),
          lease: %{id: lease.id, expires_at: lease.expires_at},
          generation: updated_room.generation
        }
      end)
      |> transaction_result()
    else
      _ -> {:error, :forbidden}
    end
  end

  defp transition_to_idle!(room, link) do
    inactivity_started_at = room.last_presence_at || room.inserted_at
    expires_at = DateTime.add(inactivity_started_at, room.idle_ttl_seconds, :second)
    generation = room.generation + 1

    updated =
      room
      |> EphemeralRoom.changeset(%{
        status: :idle,
        idle_since: inactivity_started_at,
        expires_at: expires_at,
        authority_expires_at: expires_at,
        generation: generation
      })
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> update_or_rollback()

    shorten_link_and_admissions!(updated, link, expires_at)
    Scheduler.enqueue_expiry!(updated, expires_at)

    Events.emit!(
      updated,
      "ephemeral_room.idle.v1",
      nil,
      %{expires_at: DateTime.to_iso8601(expires_at), generation: generation},
      "ephemeral-room-reconcile:#{updated.id}:#{generation}"
    )

    {:idle, expires_at, generation}
  end

  defp reactivate_room!(%EphemeralRoom{status: :active} = room, _link, _request_id),
    do: room

  defp reactivate_room!(%EphemeralRoom{status: :idle} = room, link, request_id) do
    timestamp = now()
    deadline = DateTime.add(timestamp, @authority_horizon_seconds, :second)

    updated =
      room
      |> EphemeralRoom.changeset(%{
        status: :active,
        idle_since: nil,
        expires_at: nil,
        last_presence_at: timestamp,
        authority_expires_at: deadline,
        generation: room.generation + 1
      })
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> update_or_rollback()

    updated = extend_link_and_admissions!(updated, link, deadline)

    Scheduler.enqueue_reconcile!(
      updated,
      DateTime.add(timestamp, updated.reconnect_grace_seconds, :second)
    )

    Events.emit!(
      updated,
      "ephemeral_room.reactivated.v1",
      nil,
      %{generation: updated.generation},
      request_id
    )

    updated
  end

  defp reactivate_room!(%EphemeralRoom{}, _link, _request_id),
    do: Repo.rollback(:ephemeral_room_unavailable)

  defp ensure_rolling_authority!(room, force?) do
    timestamp = now()
    refresh_after = DateTime.add(timestamp, @authority_refresh_seconds, :second)

    if force? or DateTime.compare(room.authority_expires_at, refresh_after) != :gt do
      deadline = DateTime.add(timestamp, @authority_horizon_seconds, :second)
      link = Repo.get!(GuestLink, room.guest_link_id)
      updated_room = extend_link_and_admissions!(room, link, deadline)
      {deadline, updated_room}
    else
      {room.authority_expires_at, room}
    end
  end

  defp extend_link_and_admissions!(room, link, deadline) do
    link
    |> GuestLink.changeset(%{expires_at: deadline})
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> update_or_rollback()

    active_admissions =
      Repo.all(
        from(admission in GuestAdmission,
          where:
            admission.tenant_id == ^room.tenant_id and
              admission.conversation_id == ^room.conversation_id and
              is_nil(admission.revoked_at) and is_nil(admission.converted_at),
          order_by: [asc: admission.id],
          lock: "FOR UPDATE"
        )
      )

    Enum.each(active_admissions, fn admission ->
      admission
      |> GuestAdmission.changeset(%{expires_at: deadline})
      |> update_or_rollback()

      case Accounts.ensure_ephemeral_guest_authority(admission.session_id, deadline) do
        {:ok,
         %{
           tenant_id: tenant_id,
           user_id: user_id,
           session_id: session_id,
           expires_at: expires_at
         }}
        when tenant_id == admission.tenant_id and user_id == admission.guest_user_id and
               session_id == admission.session_id and expires_at == deadline ->
          :ok

        {:error, reason} ->
          Repo.rollback(reason)

        _ ->
          Repo.rollback(:ephemeral_guest_authority_mismatch)
      end
    end)

    updated_room =
      room
      |> EphemeralRoom.changeset(%{authority_expires_at: deadline})
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> update_or_rollback()

    updated_room
  end

  defp shorten_link_and_admissions!(room, link, deadline) do
    link
    |> GuestLink.changeset(%{expires_at: deadline})
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> update_or_rollback()

    Repo.update_all(
      from(admission in GuestAdmission,
        where:
          admission.tenant_id == ^room.tenant_id and
            admission.conversation_id == ^room.conversation_id and
            is_nil(admission.revoked_at) and is_nil(admission.converted_at)
      ),
      set: [expires_at: deadline, updated_at: now()]
    )

    :ok
  end

  defp expire_locked!(conversation, link, room, timestamp, call_access_revoker) do
    admissions =
      Repo.all(
        from(admission in GuestAdmission,
          where:
            admission.tenant_id == ^room.tenant_id and
              admission.conversation_id == ^room.conversation_id,
          order_by: [asc: admission.id],
          lock: "FOR UPDATE"
        )
      )

    memberships =
      Repo.all(
        from(membership in Membership,
          where:
            membership.tenant_id == ^room.tenant_id and
              membership.conversation_id == ^room.conversation_id,
          order_by: [asc: membership.id],
          lock: "FOR UPDATE"
        )
      )

    Enum.each(admissions, fn admission ->
      if is_nil(admission.revoked_at) and is_nil(admission.converted_at) do
        case Accounts.revoke_guest_session(admission.session_id, "ephemeral_room_expired") do
          :ok -> :ok
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        admission
        |> GuestAdmission.changeset(%{revoked_at: timestamp})
        |> update_or_rollback()
      end
    end)

    Enum.each(memberships, fn membership ->
      if is_nil(membership.left_at) do
        membership
        |> Membership.changeset(%{left_at: timestamp})
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> update_or_rollback()

        case call_access_revoker.(
               room.tenant_id,
               room.conversation_id,
               membership.user_id,
               "ephemeral_room_expired"
             ) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end
    end)

    unless link.revoked_at do
      link
      |> GuestLink.changeset(%{revoked_at: timestamp, expires_at: timestamp})
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> update_or_rollback()
    end

    archived =
      if conversation.archived_at do
        conversation
      else
        conversation
        |> Conversation.changeset(%{archived_at: timestamp})
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> update_or_rollback()
      end

    case room.tenant_id
         |> CallLifecycleCommand.conversation_archived(
           room.conversation_id,
           "ephemeral_room_expired"
         )
         |> CallLifecyclePort.revoke_conversation_access() do
      {:ok, %CallLifecycleReceipt{}} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    expired =
      room
      |> EphemeralRoom.changeset(%{
        status: :expired,
        expired_at: timestamp,
        expires_at: timestamp,
        generation: room.generation + 1
      })
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> update_or_rollback()

    Events.emit!(
      expired,
      "ephemeral_room.expired.v1",
      nil,
      %{conversation_id: archived.id, generation: expired.generation},
      "ephemeral-room-expiry:#{expired.id}:#{expired.generation}"
    )

    :expired
  end

  defp provision_creator!(attrs, %{owner_kind: :guest} = scope, display_name, device, deadline) do
    authentication =
      case Accounts.provision_guest_identity(%{
             tenant_id: scope.tenant_id,
             display_name: display_name,
             device: device,
             expires_at: deadline,
             request_id: value(attrs, :request_id)
           }) do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end

    {authentication, authentication.user.id, authentication.session_id, authentication.user.id}
  end

  defp provision_creator!(
         _attrs,
         %{owner_kind: :registered, grant: grant},
         _name,
         _device,
         _deadline
       ),
       do: {nil, grant.user_id, grant.session_id, grant.user_id}

  defp maybe_create_creator_admission!(
         %{owner_kind: :guest},
         authentication,
         conversation,
         membership,
         link,
         timestamp,
         deadline
       ) do
    admission =
      %GuestAdmission{}
      |> GuestAdmission.changeset(%{
        tenant_id: conversation.tenant_id,
        conversation_id: conversation.id,
        guest_link_id: link.id,
        guest_user_id: authentication.user.id,
        membership_id: membership.id,
        session_id: authentication.session_id,
        admitted_at: timestamp,
        expires_at: deadline,
        history_from_sequence: conversation.next_sequence
      })
      |> insert_or_rollback()

    Scheduler.enqueue_guest_admission_expiry!(admission)
    admission
  end

  defp maybe_create_creator_admission!(
         %{owner_kind: :registered},
         _authentication,
         _conversation,
         _membership,
         _link,
         _timestamp,
         _deadline
       ),
       do: nil

  defp creator_scope(_attrs, :guest) do
    with {:ok, tenant_id} <- configured_public_tenant_id() do
      {:ok, %{tenant_id: tenant_id, owner_kind: :guest, account_type: :guest}}
    end
  end

  defp creator_scope(_attrs, subject) when is_map(subject) do
    with {:ok, tenant_id} <- configured_public_tenant_id(),
         {:ok,
          %{
            account_type: :human,
            access_scope: access_scope,
            tenant_id: ^tenant_id
          } = grant} <- Accounts.access_grant(subject),
         true <- access_scope in [:workspace, :conversation_only] do
      {:ok,
       %{
         tenant_id: tenant_id,
         owner_kind: :registered,
         account_type: :human,
         grant: grant
       }}
    else
      {:error, :instant_rooms_unavailable} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  defp configured_public_tenant_id do
    enabled? = Application.get_env(:comms_core, :instant_rooms_enabled, false)
    slug = Application.get_env(:comms_core, :instant_room_tenant_slug)

    if enabled? and is_binary(slug) and String.trim(slug) != "" do
      case Administration.active_tenant_by_slug(String.trim(slug)) do
        {:ok, tenant} -> {:ok, tenant.id}
        {:error, _reason} -> {:error, :instant_rooms_unavailable}
      end
    else
      {:error, :instant_rooms_unavailable}
    end
  end

  defp joiner_scope(:guest, link),
    do: {:ok, %{tenant_id: link.tenant_id, account_type: :guest}}

  defp joiner_scope(subject, link) when is_map(subject) do
    case Accounts.access_grant(subject) do
      {:ok, %{account_type: :human, tenant_id: tenant_id} = grant}
      when tenant_id == link.tenant_id ->
        {:ok, grant}

      _ ->
        {:error, :ephemeral_room_unavailable}
    end
  end

  defp creator_display_name(attrs, %{owner_kind: :guest}),
    do: display_name(value(attrs, :display_name))

  defp creator_display_name(_attrs, %{owner_kind: :registered}), do: {:ok, nil}
  defp creator_device(attrs, %{owner_kind: :guest}), do: device(value(attrs, :device))
  defp creator_device(_attrs, %{owner_kind: :registered}), do: {:ok, %{}}

  defp join_display_name(attrs, %{account_type: :guest}),
    do: display_name(value(attrs, :display_name))

  defp join_display_name(_attrs, %{account_type: :human}), do: {:ok, nil}
  defp join_device(attrs, %{account_type: :guest}), do: device(value(attrs, :device))
  defp join_device(_attrs, %{account_type: :human}), do: {:ok, %{}}

  defp display_name(value), do: Request.display_name(value)
  defp device(value), do: Request.device(value)
  defp room_title(value), do: Request.room_title(value)

  defp create_fingerprint(scope, title, display_name, device),
    do: Request.create_fingerprint(scope, title, display_name, device)

  defp join_fingerprint(link, scope, display_name, device),
    do: Request.join_fingerprint(link, scope, display_name, device)

  defp lock_room_scope_by_link!(snapshot, token_secret) do
    conversation =
      Repo.one(
        from(conversation in Conversation,
          where:
            conversation.id == ^snapshot.conversation_id and
              conversation.tenant_id == ^snapshot.tenant_id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:ephemeral_room_unavailable)

    link =
      Repo.one(
        from(link in GuestLink,
          where:
            link.id == ^snapshot.id and link.tenant_id == ^snapshot.tenant_id and
              link.conversation_id == ^snapshot.conversation_id and
              link.purpose == :ephemeral_room,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:ephemeral_room_unavailable)

    unless secure_match?(link.token_digest, digest(token_secret)),
      do: Repo.rollback(:ephemeral_room_unavailable)

    room =
      Repo.one(
        from(room in EphemeralRoom,
          where:
            room.tenant_id == ^link.tenant_id and room.conversation_id == ^link.conversation_id and
              room.guest_link_id == ^link.id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:ephemeral_room_unavailable)

    {conversation, link, room}
  end

  defp lock_room_scope!(snapshot) do
    conversation =
      Repo.one(
        from(conversation in Conversation,
          where:
            conversation.id == ^snapshot.conversation_id and
              conversation.tenant_id == ^snapshot.tenant_id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:ephemeral_room_not_found)

    link =
      Repo.one(
        from(link in GuestLink,
          where:
            link.id == ^snapshot.guest_link_id and link.tenant_id == ^snapshot.tenant_id and
              link.conversation_id == ^snapshot.conversation_id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:ephemeral_room_not_found)

    room =
      Repo.one(
        from(room in EphemeralRoom,
          where: room.id == ^snapshot.id and room.tenant_id == ^snapshot.tenant_id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:ephemeral_room_not_found)

    {conversation, link, room}
  end

  defp available_room!(room, link, conversation, timestamp) do
    case available_room(room, link, conversation, timestamp) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp available_room(room, link, conversation, timestamp) do
    available? =
      room.status in [:active, :idle] and is_nil(room.expired_at) and
        is_nil(conversation.archived_at) and link.purpose == :ephemeral_room and
        is_nil(link.revoked_at) and DateTime.compare(link.expires_at, timestamp) == :gt and
        (room.status == :active or DateTime.compare(room.expires_at, timestamp) == :gt)

    if available?, do: :ok, else: {:error, :ephemeral_room_unavailable}
  end

  defp authorize_presence!(room, grant) do
    valid_membership? =
      active_membership?(room.tenant_id, room.conversation_id, grant.user_id)

    valid_guest? =
      grant.account_type != :guest or
        Repo.exists?(
          from(admission in GuestAdmission,
            join: link in GuestLink,
            on: link.id == admission.guest_link_id,
            where:
              admission.tenant_id == ^room.tenant_id and
                admission.conversation_id == ^room.conversation_id and
                admission.guest_user_id == ^grant.user_id and
                admission.session_id == ^grant.session_id and is_nil(admission.revoked_at) and
                is_nil(admission.converted_at) and link.purpose == :ephemeral_room
          )
        )

    unless valid_membership? and valid_guest?, do: Repo.rollback(:forbidden)
  end

  defp maybe_extend_present_guest!(room, %{account_type: :guest} = grant, deadline) do
    admission =
      Repo.one(
        from(admission in GuestAdmission,
          join: link in GuestLink,
          on: link.id == admission.guest_link_id,
          where:
            admission.tenant_id == ^room.tenant_id and
              admission.conversation_id == ^room.conversation_id and
              admission.guest_user_id == ^grant.user_id and
              admission.session_id == ^grant.session_id and is_nil(admission.revoked_at) and
              is_nil(admission.converted_at) and link.purpose == :ephemeral_room,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:forbidden)

    if DateTime.compare(admission.expires_at, deadline) != :eq do
      admission
      |> GuestAdmission.changeset(%{expires_at: deadline})
      |> update_or_rollback()
    end

    :ok
  end

  defp maybe_extend_present_guest!(_room, _grant, _deadline), do: :ok

  defp lock_join_admission(link_id, idempotency_digest) do
    Repo.one(
      from(admission in GuestAdmission,
        where:
          admission.guest_link_id == ^link_id and
            admission.join_idempotency_digest == ^idempotency_digest,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_human_join_receipt(room_id, idempotency_digest) do
    Repo.one(
      from(receipt in EphemeralJoinReceipt,
        where:
          receipt.ephemeral_room_id == ^room_id and
            receipt.idempotency_digest == ^idempotency_digest,
        lock: "FOR UPDATE"
      )
    )
  end

  defp active_membership?(tenant_id, conversation_id, user_id) do
    Repo.exists?(
      from(membership in Membership,
        join: conversation in Conversation,
        on:
          conversation.id == membership.conversation_id and
            conversation.tenant_id == membership.tenant_id,
        where:
          membership.tenant_id == ^tenant_id and
            membership.conversation_id == ^conversation_id and membership.user_id == ^user_id and
            is_nil(membership.left_at) and is_nil(conversation.archived_at)
      )
    )
  end

  defp live_presence?(room_id, timestamp) do
    Repo.exists?(
      from(lease in EphemeralPresenceLease,
        where:
          lease.ephemeral_room_id == ^room_id and is_nil(lease.closed_at) and
            lease.expires_at > ^timestamp
      )
    )
  end

  defp advance_last_presence!(room, timestamp) do
    case room.last_presence_at do
      %DateTime{} = current ->
        if DateTime.compare(current, timestamp) in [:eq, :gt],
          do: room,
          else: update_last_presence!(room, timestamp)

      _ ->
        update_last_presence!(room, timestamp)
    end
  end

  defp update_last_presence!(room, timestamp) do
    room
    |> EphemeralRoom.changeset(%{last_presence_at: timestamp})
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> update_or_rollback()
  end

  defp enforce_presence_lease_limit!(room_id, user_id, timestamp) do
    active_count =
      Repo.aggregate(
        from(lease in EphemeralPresenceLease,
          where:
            lease.ephemeral_room_id == ^room_id and lease.user_id == ^user_id and
              is_nil(lease.closed_at) and lease.expires_at > ^timestamp
        ),
        :count
      )

    if active_count < @max_active_leases_per_user,
      do: :ok,
      else: Repo.rollback(:ephemeral_presence_limit_exceeded)
  end

  defp within_reconnect_grace?(room, timestamp) do
    baseline = room.last_presence_at || room.inserted_at

    DateTime.compare(DateTime.add(baseline, room.reconnect_grace_seconds, :second), timestamp) ==
      :gt
  end

  defp ensure_member_capacity(room, conversation) do
    count =
      Repo.aggregate(
        from(membership in Membership,
          where:
            membership.tenant_id == ^conversation.tenant_id and
              membership.conversation_id == ^conversation.id and is_nil(membership.left_at)
        ),
        :count
      )

    if count < room.participant_limit,
      do: :ok,
      else: {:error, :conversation_member_quota_exceeded}
  end

  defp response(room, conversation, token, authentication, admission, membership, replayed) do
    room
    |> Projection.response(
      conversation,
      token,
      authentication,
      admission,
      membership,
      replayed
    )
    |> Map.put(:capabilities, capabilities!(room.tenant_id))
  end

  defp join_response(
         room,
         conversation,
         token,
         authentication,
         admission,
         membership,
         replayed,
         membership_changed
       )
       when is_boolean(membership_changed) do
    room
    |> response(conversation, token, authentication, admission, membership, replayed)
    |> Map.put(:membership_changed, membership_changed)
  end

  defp capabilities!(tenant_id) do
    case Administration.call_policy(tenant_id) do
      {:ok, policy} ->
        %{
          allow_audio_calls: policy.allow_audio_calls,
          allow_video_calls: policy.allow_video_calls,
          conversion_enabled: true,
          self_service_conversion: true,
          email_hint: nil
        }

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp title_for(%Conversation{title: title}) when is_binary(title) and title != "", do: title
  defp title_for(_conversation), do: "Instant room"

  defp active_conversation_count(tenant_id) do
    Repo.aggregate(
      from(conversation in Conversation,
        where: conversation.tenant_id == ^tenant_id and is_nil(conversation.archived_at)
      ),
      :count
    )
  end

  defp admission_policy!(tenant_id) do
    case AdmissionQuotas.locked_policy(tenant_id) do
      {:ok, policy} -> policy
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp idle_ttl(:guest),
    do: Application.get_env(:comms_core, :instant_room_guest_idle_ttl_seconds, 3_600)

  defp idle_ttl(:registered), do: registered_idle_ttl()

  defp registered_idle_ttl,
    do: Application.get_env(:comms_core, :instant_room_registered_idle_ttl_seconds, 86_400)

  defp reconnect_grace,
    do: Application.get_env(:comms_core, :instant_room_reconnect_grace_seconds, 90)

  defp presence_lease_seconds,
    do: Application.get_env(:comms_core, :instant_room_presence_lease_seconds, 90)

  defp instant_room_max_participants,
    do: Application.get_env(:comms_core, :instant_room_max_participants, 25)

  defp exact_secret(value), do: Request.idempotency_secret(value)
  defp exact_token(value), do: Request.token_secret(value)

  defp instant_rooms_enabled do
    if Application.get_env(:comms_core, :instant_rooms_enabled, false),
      do: :ok,
      else: {:error, :ephemeral_room_unavailable}
  end

  defp cast_uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp cast_uuid(_value), do: :error

  defp secure_match?(left, right), do: Request.secure_match?(left, right)
  defp digest(value), do: Request.digest(value)

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

  defp quota_ok!(:ok), do: :ok
  defp quota_ok!({:error, reason}), do: Repo.rollback(reason)
  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp value(map, key), do: Request.value(map, key)
end
