defmodule CommsCore.Conversations.EphemeralRooms.Admission do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Accounts, Administration, Repo}

  alias CommsCore.Conversations.{
    Conversation,
    EphemeralJoinReceipt,
    EphemeralRoom,
    GuestAdmission,
    GuestLink,
    Membership
  }

  alias CommsCore.Conversations.EphemeralRooms.{
    Authority,
    Lifecycle,
    Request,
    Scheduler
  }

  @idempotency_window_seconds 10 * 60

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
    with :ok <- Authority.instant_rooms_enabled(),
         {:ok, token_secret} <- Request.token_secret(token),
         %GuestLink{purpose: :ephemeral_room} = link <-
           Repo.get_by(GuestLink, token_digest: Request.digest(token_secret)),
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
         :ok <- Authority.available_room(room, link, conversation, Authority.now()),
         {:ok, _tenant} <- Administration.active_tenant(room.tenant_id) do
      {:ok,
       %{
         room_id: room.id,
         room_title: Authority.title_for(conversation),
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
    with :ok <- Authority.instant_rooms_enabled(),
         {:ok, token_secret} <- Request.token_secret(token),
         {:ok, idempotency_secret} <-
           Request.idempotency_secret(Request.value(attrs, :idempotency_key)),
         %GuestLink{purpose: :ephemeral_room} = link_snapshot <-
           Repo.get_by(GuestLink, token_digest: Request.digest(token_secret)),
         {:ok, joiner_scope} <- joiner_scope(joiner, link_snapshot),
         {:ok, display_name} <- join_display_name(attrs, joiner_scope),
         {:ok, device} <- join_device(attrs, joiner_scope) do
      idempotency_digest = Request.digest(idempotency_secret)

      request_fingerprint =
        Request.join_fingerprint(link_snapshot, joiner_scope, display_name, device)

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
      _policy = Authority.admission_policy!(link_snapshot.tenant_id)

      {conversation, link, room} =
        Authority.lock_room_scope_by_link!(link_snapshot, token_secret)

      timestamp = Authority.now()
      Authority.available_room!(room, link, conversation, timestamp)
      room = Lifecycle.reactivate_room!(room, link, Request.value(attrs, :request_id))

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
    |> Authority.transaction_result()
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
        Authority.quota_ok!(Authority.ensure_member_capacity(room, conversation))
        {deadline, room} = Authority.ensure_rolling_authority!(room, false)
        admitted_at = Authority.now()
        idempotency_expires_at = DateTime.add(admitted_at, @idempotency_window_seconds, :second)

        authentication =
          case Accounts.provision_guest_identity(%{
                 tenant_id: room.tenant_id,
                 display_name: display_name,
                 device: device,
                 expires_at: deadline,
                 request_id: Request.value(attrs, :request_id)
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
            joined_at: Authority.now(),
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

        Authority.join_response(
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
    if not Request.secure_match?(admission.request_fingerprint, request_fingerprint),
      do: Repo.rollback(:idempotency_conflict)

    if DateTime.compare(admission.idempotency_expires_at, Authority.now()) != :gt,
      do: Repo.rollback(:idempotency_replay_expired)

    membership = Repo.get!(Membership, admission.membership_id)
    {deadline, room} = Authority.ensure_rolling_authority!(room, false)

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

    Authority.join_response(
      room,
      conversation,
      nil,
      authentication,
      updated,
      membership,
      true,
      false
    )
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
        if not Request.secure_match?(receipt.request_fingerprint, request_fingerprint),
          do: Repo.rollback(:idempotency_conflict)

        if DateTime.compare(receipt.expires_at, Authority.now()) != :gt,
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

        Authority.join_response(room, conversation, nil, nil, nil, membership, true, false)

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
              Authority.quota_ok!(Authority.ensure_member_capacity(room, conversation))

              reactivated =
                departed
                |> Membership.changeset(%{
                  role: :member,
                  joined_at: Authority.now(),
                  left_at: nil
                })
                |> Ecto.Changeset.optimistic_lock(:lock_version)
                |> update_or_rollback()

              {reactivated, true}

            nil when joiner_scope.access_scope in [:workspace, :conversation_only] ->
              Authority.quota_ok!(Authority.ensure_member_capacity(room, conversation))

              inserted =
                %Membership{}
                |> Membership.changeset(%{
                  tenant_id: room.tenant_id,
                  conversation_id: room.conversation_id,
                  user_id: joiner_scope.user_id,
                  role: :member,
                  joined_at: Authority.now(),
                  last_read_sequence: max(conversation.next_sequence - 1, 0)
                })
                |> insert_or_rollback()

              {inserted, true}

            _ ->
              Repo.rollback(:forbidden)
          end

        timestamp = Authority.now()

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

        Authority.join_response(
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

  defp join_display_name(attrs, %{account_type: :guest}),
    do: Request.display_name(Request.value(attrs, :display_name))

  defp join_display_name(_attrs, %{account_type: :human}), do: {:ok, nil}

  defp join_device(attrs, %{account_type: :guest}),
    do: Request.device(Request.value(attrs, :device))

  defp join_device(_attrs, %{account_type: :human}), do: {:ok, %{}}

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
