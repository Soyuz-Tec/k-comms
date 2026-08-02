defmodule CommsCore.AudioCalls.Collaboration do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.AudioCalls.{
    AudioCall,
    AudioCallParticipant,
    AuthorizationPolicy,
    CallParticipantView,
    ModerationTarget,
    Participants
  }

  alias CommsCore.{Audit, Repo}

  def list_participants(conversation_id, call_id, subject)
      when is_binary(conversation_id) and is_binary(call_id) and is_map(subject) do
    with {:ok, call} <- active_call(conversation_id, call_id, subject),
         :ok <- AuthorizationPolicy.authorize(:read_call, subject, call) do
      participants =
        AudioCallParticipant
        |> where(
          [participant],
          participant.tenant_id == ^call.tenant_id and
            participant.audio_call_id == ^call.id and participant.status == :admitted
        )
        |> order_by([participant], asc: participant.admitted_at, asc: participant.id)
        |> Repo.all()
        |> Enum.map(&participant_view/1)

      {:ok, participants}
    end
  end

  def list_participants(_, _, _), do: {:error, :not_found}

  def authorize_participant(conversation_id, call_id, subject)
      when is_binary(conversation_id) and is_binary(call_id) and is_map(subject) do
    with {:ok, call} <- active_call(conversation_id, call_id, subject),
         :ok <- AuthorizationPolicy.authorize(:read_call, subject, call),
         true <-
           Repo.exists?(
             from(participant in AudioCallParticipant,
               where:
                 participant.tenant_id == ^call.tenant_id and
                   participant.audio_call_id == ^call.id and
                   participant.session_id == ^value(subject, :session_id) and
                   participant.status == :admitted
             )
           ) do
      :ok
    else
      false -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  def authorize_participant(_, _, _), do: {:error, :not_found}

  def set_hand(conversation_id, call_id, raised, subject)
      when is_binary(conversation_id) and is_binary(call_id) and is_boolean(raised) and
             is_map(subject) do
    Repo.transaction(fn ->
      call = locked_active_call!(conversation_id, call_id, subject)
      authorize_or_rollback(:read_call, subject, call)

      participant =
        Repo.one(
          from(participant in AudioCallParticipant,
            where:
              participant.tenant_id == ^call.tenant_id and
                participant.audio_call_id == ^call.id and
                participant.session_id == ^value(subject, :session_id) and
                participant.status == :admitted,
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:not_found)

      participant =
        participant
        |> AudioCallParticipant.admission_changeset(%{
          hand_raised_at: if(raised, do: now(), else: nil)
        })
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> update_or_rollback()

      audit_or_rollback(
        Audit.record(%{
          tenant_id: call.tenant_id,
          actor_user_id: value(subject, :user_id),
          action: if(raised, do: "call.hand_raised", else: "call.hand_lowered"),
          resource_type: "call",
          resource_id: call.id,
          metadata: %{conversation_id: call.conversation_id},
          request_id: value(subject, :request_id)
        })
      )

      participant_view(participant)
    end)
    |> unwrap()
  end

  def set_hand(_, _, _, _), do: {:error, :invalid_call_signal}

  def moderation_target(conversation_id, call_id, provider_identity, subject)
      when is_binary(conversation_id) and is_binary(call_id) and is_binary(provider_identity) and
             is_map(subject) do
    with {:ok, call} <- active_call(conversation_id, call_id, subject),
         :ok <- AuthorizationPolicy.authorize(end_action(call), subject, call),
         %AudioCallParticipant{} = participant <-
           Repo.one(
             from(participant in AudioCallParticipant,
               where:
                 participant.tenant_id == ^call.tenant_id and
                   participant.audio_call_id == ^call.id and
                   participant.provider_identity == ^provider_identity and
                   participant.status == :admitted
             )
           ) do
      {:ok,
       %ModerationTarget{
         call_id: call.id,
         participant_id: participant.id,
         user_id: participant.user_id,
         provider_room: call.provider_room,
         provider_identity: participant.provider_identity
       }}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def moderation_target(_, _, _, _), do: {:error, :not_found}

  def remove_participant(conversation_id, call_id, provider_identity, subject)
      when is_binary(conversation_id) and is_binary(call_id) and is_binary(provider_identity) and
             is_map(subject) do
    Repo.transaction(fn ->
      target =
        case moderation_target(conversation_id, call_id, provider_identity, subject) do
          {:ok, target} -> target
          {:error, reason} -> Repo.rollback(reason)
        end

      if target.user_id == value(subject, :user_id), do: Repo.rollback(:forbidden)

      case Participants.revoke_for_call_participant(
             value(subject, :tenant_id),
             call_id,
             target.participant_id,
             "moderator_removed"
           ) do
        {:ok, count} when count > 0 -> :ok
        {:ok, _count} -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end

      audit_or_rollback(
        Audit.record(%{
          tenant_id: value(subject, :tenant_id),
          actor_user_id: value(subject, :user_id),
          action: "call.participant_removed",
          resource_type: "call_participant",
          resource_id: target.participant_id,
          metadata: %{conversation_id: conversation_id, call_id: call_id},
          request_id: value(subject, :request_id)
        })
      )

      target
    end)
    |> unwrap()
  end

  def remove_participant(_, _, _, _), do: {:error, :not_found}

  def record_mute(%ModerationTarget{} = target, conversation_id, subject) do
    Audit.record(%{
      tenant_id: value(subject, :tenant_id),
      actor_user_id: value(subject, :user_id),
      action: "call.participant_muted",
      resource_type: "call_participant",
      resource_id: target.participant_id,
      metadata: %{conversation_id: conversation_id, call_id: target.call_id},
      request_id: value(subject, :request_id)
    })
  end

  defp active_call(conversation_id, call_id, subject) do
    case Repo.get_by(AudioCall,
           id: call_id,
           conversation_id: conversation_id,
           tenant_id: value(subject, :tenant_id),
           status: :active
         ) do
      %AudioCall{} = call ->
        if DateTime.compare(call.expires_at, now()) == :gt,
          do: {:ok, call},
          else: {:error, :audio_call_expired}

      nil ->
        {:error, :not_found}
    end
  end

  defp locked_active_call!(conversation_id, call_id, subject) do
    Repo.one(
      from(call in AudioCall,
        where:
          call.id == ^call_id and call.conversation_id == ^conversation_id and
            call.tenant_id == ^value(subject, :tenant_id) and call.status == :active,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  defp participant_view(participant) do
    %CallParticipantView{
      id: participant.id,
      user_id: participant.user_id,
      status: participant.status,
      hand_raised: not is_nil(participant.hand_raised_at),
      hand_raised_at: participant.hand_raised_at
    }
  end

  defp end_action(%AudioCall{media_kind: :video}), do: :end_video_call
  defp end_action(_call), do: :end_audio_call

  defp authorize_or_rollback(action, subject, resource) do
    case AuthorizationPolicy.authorize(action, subject, resource) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp audit_or_rollback({:ok, value}), do: value
  defp audit_or_rollback({:error, reason}), do: Repo.rollback(reason)
  defp unwrap({:ok, value}), do: {:ok, value}
  defp unwrap({:error, reason}), do: {:error, reason}
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
