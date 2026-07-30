defmodule CommsCore.Conversations.EphemeralRooms.Authority do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Accounts, Administration, AdmissionQuotas, Repo}

  alias CommsCore.Conversations.{
    Conversation,
    EphemeralRoom,
    EphemeralRoomView,
    GuestAdmission,
    GuestLink,
    Membership
  }

  alias CommsCore.Conversations.EphemeralRooms.{Projection, Request}

  @authority_horizon_seconds 24 * 60 * 60
  @authority_refresh_seconds 12 * 60 * 60

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

  def configured_public_tenant_id do
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

  def lock_room_scope_by_link!(snapshot, token_secret) do
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

    unless Request.secure_match?(link.token_digest, Request.digest(token_secret)),
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

  def lock_room_scope!(snapshot) do
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

  def available_room!(room, link, conversation, timestamp) do
    case available_room(room, link, conversation, timestamp) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  def available_room(room, link, conversation, timestamp) do
    available? =
      room.status in [:active, :idle] and is_nil(room.expired_at) and
        is_nil(conversation.archived_at) and link.purpose == :ephemeral_room and
        is_nil(link.revoked_at) and DateTime.compare(link.expires_at, timestamp) == :gt and
        (room.status == :active or DateTime.compare(room.expires_at, timestamp) == :gt)

    if available?, do: :ok, else: {:error, :ephemeral_room_unavailable}
  end

  def ensure_rolling_authority!(room, force?) do
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

  def extend_link_and_admissions!(room, link, deadline) do
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

    room
    |> EphemeralRoom.changeset(%{authority_expires_at: deadline})
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> update_or_rollback()
  end

  def shorten_link_and_admissions!(room, link, deadline) do
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

  def active_membership?(tenant_id, conversation_id, user_id) do
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

  def ensure_member_capacity(room, conversation) do
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

  def response(room, conversation, token, authentication, admission, membership, replayed) do
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

  def join_response(
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

  def capabilities!(tenant_id) do
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

  def title_for(%Conversation{title: title}) when is_binary(title) and title != "", do: title
  def title_for(_conversation), do: "Instant room"

  def active_conversation_count(tenant_id) do
    Repo.aggregate(
      from(conversation in Conversation,
        where: conversation.tenant_id == ^tenant_id and is_nil(conversation.archived_at)
      ),
      :count
    )
  end

  def admission_policy!(tenant_id) do
    case AdmissionQuotas.locked_policy(tenant_id) do
      {:ok, policy} -> policy
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  def idle_ttl(:guest),
    do: Application.get_env(:comms_core, :instant_room_guest_idle_ttl_seconds, 3_600)

  def idle_ttl(:registered), do: registered_idle_ttl()

  def registered_idle_ttl,
    do: Application.get_env(:comms_core, :instant_room_registered_idle_ttl_seconds, 86_400)

  def reconnect_grace,
    do: Application.get_env(:comms_core, :instant_room_reconnect_grace_seconds, 90)

  def presence_lease_seconds,
    do: Application.get_env(:comms_core, :instant_room_presence_lease_seconds, 90)

  def instant_room_max_participants,
    do: Application.get_env(:comms_core, :instant_room_max_participants, 25)

  def instant_rooms_enabled do
    if Application.get_env(:comms_core, :instant_rooms_enabled, false),
      do: :ok,
      else: {:error, :ephemeral_room_unavailable}
  end

  def cast_uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  def cast_uuid(_value), do: :error

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  def quota_ok!(:ok), do: :ok
  def quota_ok!({:error, reason}), do: Repo.rollback(reason)
  def transaction_result({:ok, result}), do: {:ok, result}
  def transaction_result({:error, reason}), do: {:error, reason}
  def now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
