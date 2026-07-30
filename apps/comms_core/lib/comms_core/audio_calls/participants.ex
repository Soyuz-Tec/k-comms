defmodule CommsCore.AudioCalls.Participants do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.AudioCalls.{AudioCall, AudioCallParticipant, Projector}
  alias CommsCore.{Repo, RuntimePorts}

  @media_kinds [:audio, :video]

  @doc false
  def admit_and_issue!(call, subject, issuer) when is_function(issuer, 1) do
    participant = active_admission!(call, subject)
    credential = issue_credential!(call, participant, issuer)
    {participant, credential}
  end

  def revoke_for_sessions(tenant_id, session_ids, reason)
      when is_binary(tenant_id) and is_list(session_ids) and is_binary(reason) do
    ids = Enum.filter(session_ids, &is_binary/1) |> Enum.uniq()

    revoke_matching(
      from(participant in AudioCallParticipant,
        where: participant.tenant_id == ^tenant_id and participant.session_id in ^ids
      ),
      reason
    )
  end

  def revoke_for_sessions(_, _, _), do: {:error, :invalid_audio_revocation_scope}

  def revoke_for_device(tenant_id, device_id, reason)
      when is_binary(tenant_id) and is_binary(device_id) and is_binary(reason) do
    revoke_matching(
      from(participant in AudioCallParticipant,
        where: participant.tenant_id == ^tenant_id and participant.device_id == ^device_id
      ),
      reason
    )
  end

  def revoke_for_device(_, _, _), do: {:error, :invalid_audio_revocation_scope}

  def revoke_for_user(tenant_id, user_id, reason)
      when is_binary(tenant_id) and is_binary(user_id) and is_binary(reason) do
    revoke_matching(
      from(participant in AudioCallParticipant,
        where: participant.tenant_id == ^tenant_id and participant.user_id == ^user_id
      ),
      reason
    )
  end

  def revoke_for_user(_, _, _), do: {:error, :invalid_audio_revocation_scope}

  def revoke_for_membership(tenant_id, conversation_id, user_id, reason)
      when is_binary(tenant_id) and is_binary(conversation_id) and is_binary(user_id) and
             is_binary(reason) do
    revoke_matching(
      from(participant in AudioCallParticipant,
        where:
          participant.tenant_id == ^tenant_id and
            participant.conversation_id == ^conversation_id and participant.user_id == ^user_id
      ),
      reason
    )
  end

  def revoke_for_membership(_, _, _, _), do: {:error, :invalid_audio_revocation_scope}

  def revoke_for_conversation(tenant_id, conversation_id, reason)
      when is_binary(tenant_id) and is_binary(conversation_id) and is_binary(reason) do
    revoke_matching(
      from(participant in AudioCallParticipant,
        where:
          participant.tenant_id == ^tenant_id and
            participant.conversation_id == ^conversation_id
      ),
      reason
    )
  end

  def revoke_for_conversation(_, _, _), do: {:error, :invalid_audio_revocation_scope}

  def revoke_for_tenant(tenant_id, reason) when is_binary(tenant_id) and is_binary(reason) do
    revoke_matching(
      from(participant in AudioCallParticipant, where: participant.tenant_id == ^tenant_id),
      reason
    )
  end

  def revoke_for_tenant(_, _), do: {:error, :invalid_audio_revocation_scope}

  def revoke_for_tenant_kind(tenant_id, media_kind, reason)
      when is_binary(tenant_id) and media_kind in @media_kinds and is_binary(reason) do
    revoke_matching(
      from(participant in AudioCallParticipant,
        where:
          participant.tenant_id == ^tenant_id and
            participant.audio_call_id in subquery(
              from(call in AudioCall,
                where: call.tenant_id == ^tenant_id and call.media_kind == ^media_kind,
                select: call.id
              )
            )
      ),
      reason
    )
  end

  def revoke_for_tenant_kind(_, _, _), do: {:error, :invalid_audio_revocation_scope}

  def revoke_for_call(tenant_id, call_id, reason)
      when is_binary(tenant_id) and is_binary(call_id) and is_binary(reason) do
    revoke_matching(
      from(participant in AudioCallParticipant,
        where: participant.tenant_id == ^tenant_id and participant.audio_call_id == ^call_id
      ),
      reason
    )
  end

  def revoke_for_call(_, _, _), do: {:error, :invalid_audio_revocation_scope}

  def claim_eviction(participant_id, caller) when is_binary(participant_id) do
    if RuntimePorts.authorized_job_worker?(:audio_participant_eviction, caller) do
      Repo.transaction(fn ->
        participant = lock_participant!(participant_id)

        if participant.eviction_status in [:pending, :enforcing] do
          call = Repo.get(AudioCall, participant.audio_call_id) || Repo.rollback(:not_found)
          Projector.eviction_claim(participant, call)
        else
          Repo.rollback(:not_claimable)
        end
      end)
      |> unwrap()
    else
      {:error, :forbidden}
    end
  end

  def claim_eviction(_, _), do: {:error, :not_found}

  def record_eviction(participant_id, result, %DateTime{} = attempt_started_at, caller)
      when is_binary(participant_id) and result in [:removed, :failed] do
    if RuntimePorts.authorized_job_worker?(:audio_participant_eviction, caller) do
      Repo.transaction(fn ->
        participant = lock_participant!(participant_id)
        timestamp = now()

        completed? =
          result == :removed and
            DateTime.compare(participant.eviction_enforce_until, attempt_started_at) != :gt

        attrs = %{
          last_eviction_attempt_at: attempt_started_at,
          eviction_attempts: participant.eviction_attempts + 1,
          eviction_status:
            if(completed?,
              do: :completed,
              else: if(result == :removed, do: :enforcing, else: :pending)
            )
        }

        attrs =
          if result == :removed do
            Map.merge(attrs, %{
              status: :evicted,
              last_eviction_success_at: attempt_started_at,
              evicted_at: participant.evicted_at || timestamp
            })
          else
            attrs
          end

        participant
        |> AudioCallParticipant.admission_changeset(attrs)
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> update_or_rollback()
        |> Projector.eviction_progress()
      end)
      |> unwrap()
    else
      {:error, :forbidden}
    end
  end

  def record_eviction(_, _, _, _), do: {:error, :not_found}

  defp active_admission!(call, subject) do
    session_id = value(subject, :session_id) || Repo.rollback(:forbidden)

    case Repo.one(
           from(participant in AudioCallParticipant,
             where:
               participant.tenant_id == ^call.tenant_id and
                 participant.audio_call_id == ^call.id and
                 participant.session_id == ^session_id and participant.status == :admitted,
             lock: "FOR UPDATE"
           )
         ) do
      %AudioCallParticipant{} = participant -> participant
      nil -> create_admission!(call, subject)
    end
  end

  defp create_admission!(call, subject) do
    timestamp = now()

    %AudioCallParticipant{}
    |> AudioCallParticipant.admission_changeset(%{
      tenant_id: call.tenant_id,
      audio_call_id: call.id,
      conversation_id: call.conversation_id,
      user_id: value(subject, :user_id),
      device_id: value(subject, :device_id),
      session_id: value(subject, :session_id),
      provider_identity: new_provider_identity(),
      status: :admitted,
      admitted_at: timestamp,
      credential_issue_count: 0,
      eviction_status: :not_required,
      eviction_attempts: 0
    })
    |> insert_or_rollback()
  end

  defp issue_credential!(call, participant, issuer) do
    case issuer.(Projector.credential_request(call, participant)) do
      {:ok, credential} ->
        record_credential_issuance!(participant)
        credential

      {:error, reason} ->
        Repo.rollback(reason)

      _ ->
        Repo.rollback(:audio_provider_unavailable)
    end
  end

  defp record_credential_issuance!(participant) do
    participant
    |> AudioCallParticipant.admission_changeset(%{
      credential_issued_at: now(),
      credential_issue_count: participant.credential_issue_count + 1
    })
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> update_or_rollback()
  end

  defp revoke_matching(query, reason) do
    with {:ok, normalized_reason} <- revocation_reason(reason) do
      Repo.transaction(fn ->
        participants =
          query
          |> where(
            [participant],
            participant.status == :admitted and
              participant.audio_call_id in subquery(
                from(call in AudioCall,
                  where: call.status in [:active, :ending],
                  select: call.id
                )
              )
          )
          |> order_by([participant], asc: participant.id)
          |> lock("FOR UPDATE")
          |> Repo.all()

        Enum.each(participants, &revoke_participant!(&1, normalized_reason))
        length(participants)
      end)
      |> unwrap()
    end
  end

  defp revoke_participant!(participant, reason) do
    timestamp = now()

    revoked =
      participant
      |> AudioCallParticipant.admission_changeset(%{
        status: :revoked,
        revoked_at: timestamp,
        revocation_reason: reason,
        eviction_status: :pending,
        eviction_enforce_until:
          DateTime.add(timestamp, participant_eviction_enforcement_seconds(), :second)
      })
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> update_or_rollback()

    %{"participant_id" => revoked.id, "tenant_id" => revoked.tenant_id}
    |> Oban.Job.new(
      worker: RuntimePorts.job_worker_name!(:audio_participant_eviction),
      queue: :media,
      unique: [
        period: :infinity,
        fields: [:worker, :args],
        states: [:available, :scheduled, :executing, :retryable]
      ]
    )
    |> insert_or_rollback()

    revoked
  end

  defp lock_participant!(participant_id) do
    Repo.one(
      from(participant in AudioCallParticipant,
        where: participant.id == ^participant_id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  defp revocation_reason(reason) do
    reason = String.trim(reason)

    if String.length(reason) in 3..120,
      do: {:ok, reason},
      else: {:error, :invalid_audio_revocation_reason}
  end

  defp participant_eviction_enforcement_seconds do
    Application.get_env(:comms_core, :audio_participant_eviction_enforcement_seconds, 660)
  end

  defp new_provider_identity do
    "kc_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
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

  defp unwrap({:ok, result}), do: {:ok, result}
  defp unwrap({:error, reason}), do: {:error, reason}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
