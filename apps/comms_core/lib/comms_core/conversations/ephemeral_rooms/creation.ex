defmodule CommsCore.Conversations.EphemeralRooms.Creation do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Accounts, AdmissionQuotas, Repo}

  alias CommsCore.Conversations.{
    Conversation,
    EphemeralReplayBox,
    EphemeralRoom,
    GuestAdmission,
    GuestLink,
    Membership
  }

  alias CommsCore.Conversations.EphemeralRooms.{Authority, Events, Request, Scheduler}

  @authority_horizon_seconds 24 * 60 * 60
  @idempotency_window_seconds 10 * 60

  @spec create(map(), :guest | map()) :: {:ok, map()} | {:error, term()}
  def create(attrs, creator) when is_map(attrs) and (creator == :guest or is_map(creator)) do
    with {:ok, idempotency_secret} <-
           Request.idempotency_secret(Request.value(attrs, :idempotency_key)),
         {:ok, creator_scope} <- creator_scope(creator),
         {:ok, title} <- Request.room_title(Request.value(attrs, :title)),
         {:ok, display_name} <- creator_display_name(attrs, creator_scope),
         {:ok, device} <- creator_device(attrs, creator_scope) do
      idempotency_digest = Request.digest(idempotency_secret)

      request_fingerprint =
        Request.create_fingerprint(creator_scope, title, display_name, device)

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
        timestamp = Authority.now()
        authority_expires_at = DateTime.add(timestamp, @authority_horizon_seconds, :second)
        idempotency_expires_at = DateTime.add(timestamp, @idempotency_window_seconds, :second)
        policy = Authority.admission_policy!(creator_scope.tenant_id)

        participant_limit =
          min(Authority.instant_room_max_participants(), policy.max_conversation_members)

        Authority.quota_ok!(
          AdmissionQuotas.check_conversation_creation(
            policy,
            Authority.active_conversation_count(creator_scope.tenant_id),
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
            token_digest: Request.digest(token_secret),
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
            reconnect_grace_seconds: Authority.reconnect_grace(),
            idle_ttl_seconds: Authority.idle_ttl(creator_scope.owner_kind),
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
          Request.value(attrs, :request_id)
        )

        Authority.response(
          room,
          conversation,
          token,
          authentication,
          admission,
          membership,
          false
        )
      end)
      |> Authority.transaction_result()
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
          {_conversation, _link, room} = Authority.lock_room_scope!(snapshot)
          replay_creation_locked!(room, creator_scope, request_fingerprint, device)
        end)
        |> Authority.transaction_result()
    end
  end

  defp replay_creation_locked!(room, creator_scope, request_fingerprint, device) do
    timestamp = Authority.now()

    if not Request.secure_match?(room.request_fingerprint, request_fingerprint),
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

    Authority.response(room, conversation, token, authentication, admission, membership, true)
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

    {deadline, room} = Authority.ensure_rolling_authority!(room, false)

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

  defp provision_creator!(attrs, %{owner_kind: :guest} = scope, display_name, device, deadline) do
    authentication =
      case Accounts.provision_guest_identity(%{
             tenant_id: scope.tenant_id,
             display_name: display_name,
             device: device,
             expires_at: deadline,
             request_id: Request.value(attrs, :request_id)
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

  defp creator_scope(:guest) do
    with {:ok, tenant_id} <- Authority.configured_public_tenant_id() do
      {:ok, %{tenant_id: tenant_id, owner_kind: :guest, account_type: :guest}}
    end
  end

  defp creator_scope(subject) when is_map(subject) do
    with {:ok, tenant_id} <- Authority.configured_public_tenant_id(),
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

  defp creator_display_name(attrs, %{owner_kind: :guest}),
    do: Request.display_name(Request.value(attrs, :display_name))

  defp creator_display_name(_attrs, %{owner_kind: :registered}), do: {:ok, nil}

  defp creator_device(attrs, %{owner_kind: :guest}),
    do: Request.device(Request.value(attrs, :device))

  defp creator_device(_attrs, %{owner_kind: :registered}), do: {:ok, %{}}

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
