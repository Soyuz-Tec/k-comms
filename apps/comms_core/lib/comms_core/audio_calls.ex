defmodule CommsCore.AudioCalls do
  import Ecto.Query

  alias CommsCore.AudioCalls.{AudioCall, AudioCallParticipant}
  alias CommsCore.Accounts.Session
  alias CommsCore.Administration.Tenant
  alias CommsCore.Audit
  alias CommsCore.Conversations.Conversation
  alias CommsCore.Conversations.Membership
  alias CommsCore.{Authorization, Outbox, Repo, RuntimePorts}

  @maximum_call_seconds 8 * 60 * 60
  @media_kinds [:audio, :video]

  def start(conversation_id, subject),
    do: start(conversation_id, subject, :audio, &provider_cleanup_required/1)

  def start(conversation_id, subject, provider_cleanup)
      when is_binary(conversation_id) and is_map(subject) and
             is_function(provider_cleanup, 1) do
    start(conversation_id, subject, :audio, provider_cleanup)
  end

  def start(conversation_id, subject, media_kind)
      when is_binary(conversation_id) and is_map(subject) and media_kind in @media_kinds do
    start(conversation_id, subject, media_kind, &provider_cleanup_required/1)
  end

  def start(_, _, _), do: {:error, :not_found}

  def start(conversation_id, subject, media_kind, provider_cleanup)
      when is_binary(conversation_id) and is_map(subject) and media_kind in @media_kinds and
             is_function(provider_cleanup, 1) do
    action = start_action(media_kind)

    with :ok <- Authorization.authorize(action, subject, %{id: conversation_id}) do
      Repo.transaction(fn ->
        conversation = lock_conversation!(conversation_id, subject)
        authorize!(action, subject, conversation)
        start_locked!(conversation, subject, media_kind, provider_cleanup)
      end)
      |> unwrap_start()
    end
  end

  def start(_, _, _, _), do: {:error, :invalid_media_kind}

  def start_with_kind(conversation_id, subject, media_kind),
    do: start(conversation_id, subject, media_kind)

  def start_with_kind(conversation_id, subject, media_kind, provider_cleanup),
    do: start(conversation_id, subject, media_kind, provider_cleanup)

  @doc """
  Atomically starts or replays a call and issues the starter credential.

  The call, expiry job, audit record, outbox events, admission, and credential
  issuance bookkeeping share one transaction. If the issuer fails or the
  caller loses authority while waiting for locks, a newly started call leaves
  no durable artifacts.
  """
  def start_with_join_authorized(
        conversation_id,
        subject,
        media_kind,
        provider_cleanup,
        issuer
      )
      when is_binary(conversation_id) and is_map(subject) and media_kind in @media_kinds and
             is_function(provider_cleanup, 1) and is_function(issuer, 2) do
    action = start_action(media_kind)

    with :ok <- Authorization.authorize(action, subject, %{id: conversation_id}) do
      Repo.transaction(fn ->
        conversation = lock_start_join_authority!(conversation_id, subject)
        authorize!(action, subject, conversation)
        authorize!(join_action(media_kind), subject, conversation)

        {call, status} = start_locked!(conversation, subject, media_kind, provider_cleanup)
        ensure_active!(call)
        participant = active_admission!(call, subject)
        credential = issue_credential!(call, participant, issuer)

        {call, status, credential}
      end)
      |> unwrap_start_join()
    end
  end

  def start_with_join_authorized(_, _, _, _, _), do: {:error, :invalid_media_kind}

  def get_active(conversation_id, subject)
      when is_binary(conversation_id) and is_map(subject) do
    with :ok <- Authorization.authorize(:read_call, subject, %{id: conversation_id}) do
      call =
        Repo.one(
          from(call in AudioCall,
            where:
              call.tenant_id == ^value(subject, :tenant_id) and
                call.conversation_id == ^conversation_id and call.status == :active and
                call.expires_at > ^now(),
            limit: 1
          )
        )

      with :ok <- authorize_active_call(call, subject) do
        {:ok, call}
      end
    end
  end

  def get_active(_, _), do: {:error, :not_found}

  def get_active(conversation_id, subject, expected_kind) when expected_kind in @media_kinds do
    with {:ok, call} <- get_active(conversation_id, subject),
         :ok <- ensure_media_kind(call, expected_kind) do
      {:ok, call}
    end
  end

  def get_active(_, _, _), do: {:error, :invalid_media_kind}

  def authorize_join(conversation_id, call_id, subject)
      when is_binary(conversation_id) and is_binary(call_id) and is_map(subject) do
    case with_join_authorized(conversation_id, call_id, subject, fn _call, _participant ->
           {:ok, :authorized}
         end) do
      {:ok, call, :authorized} -> {:ok, call}
      {:error, _} = error -> error
    end
  end

  def authorize_join(_, _, _), do: {:error, :not_found}

  @doc """
  Executes credential issuance while holding the call row lock.

  End transitions use the same lock, so the issuer cannot run after a call has
  entered `ending`. The callback participates in this transaction, which also
  provides the extension point for atomically registering the issued provider
  participant identity. The returned credential is never persisted by this
  module.
  """
  def with_join_authorized(conversation_id, call_id, subject, issuer)
      when is_binary(conversation_id) and is_binary(call_id) and is_map(subject) and
             is_function(issuer, 2) do
    with_join_authorized(conversation_id, call_id, subject, nil, issuer)
  end

  def with_join_authorized(_, _, _, _), do: {:error, :not_found}

  def with_join_authorized(conversation_id, call_id, subject, expected_kind, issuer)
      when is_binary(conversation_id) and is_binary(call_id) and is_map(subject) and
             (is_nil(expected_kind) or expected_kind in @media_kinds) and is_function(issuer, 2) do
    Repo.transaction(fn ->
      lock_join_authority!(conversation_id, subject)
      call = lock_call!(conversation_id, call_id, subject)
      ensure_media_kind!(call, expected_kind)
      authorize!(join_action(call.media_kind), subject, call)
      ensure_active!(call)
      participant = active_admission!(call, subject)
      credential = issue_credential!(call, participant, issuer)
      {call, credential}
    end)
    |> unwrap_join()
  end

  def with_join_authorized(_, _, _, _, _), do: {:error, :not_found}

  @doc "Revokes active admissions for exact sessions and durably schedules provider eviction."
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

  @doc "Revokes active admissions issued to one device."
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

  @doc "Revokes every active admission for a tenant user."
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

  @doc "Revokes one member's active admission to an exact conversation."
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

  @doc "Revokes every active admission in an exact conversation."
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

  @doc "Revokes all active realtime-media admissions for a tenant."
  def revoke_for_tenant(tenant_id, reason) when is_binary(tenant_id) and is_binary(reason) do
    revoke_matching(
      from(participant in AudioCallParticipant, where: participant.tenant_id == ^tenant_id),
      reason
    )
  end

  def revoke_for_tenant(_, _), do: {:error, :invalid_audio_revocation_scope}

  @doc "Revokes active admissions for exactly one media kind in a tenant."
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

  @doc "Revokes every active admission for one call after provider room termination."
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

  @doc false
  def claim_participant_eviction(participant_id, caller) when is_binary(participant_id) do
    if RuntimePorts.authorized_job_worker?(:audio_participant_eviction, caller) do
      Repo.transaction(fn ->
        participant = lock_participant!(participant_id)

        if participant.eviction_status in [:pending, :enforcing] do
          call = Repo.get(AudioCall, participant.audio_call_id) || Repo.rollback(:not_found)

          %{
            participant_id: participant.id,
            provider_identity: participant.provider_identity,
            call: call,
            enforce_until: participant.eviction_enforce_until
          }
        else
          Repo.rollback(:not_claimable)
        end
      end)
      |> unwrap()
    else
      {:error, :forbidden}
    end
  end

  def claim_participant_eviction(_, _), do: {:error, :not_found}

  @doc false
  def record_participant_eviction(
        participant_id,
        result,
        %DateTime{} = attempt_started_at,
        caller
      )
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
      end)
      |> unwrap()
    else
      {:error, :forbidden}
    end
  end

  def record_participant_eviction(_, _, _, _), do: {:error, :not_found}

  @doc false
  def expire_call(call_id, caller, provider_cleanup)
      when is_binary(call_id) and is_function(provider_cleanup, 1) do
    if RuntimePorts.authorized_job_worker?(:audio_call_expiry, caller) do
      Repo.transaction(fn ->
        call = lock_call_by_id!(call_id)

        case call.status do
          :ended ->
            {:already_ended, call}

          :ending ->
            Repo.rollback(:audio_call_ending)

          :active ->
            if DateTime.compare(call.expires_at, now()) == :gt do
              {:not_due, max(DateTime.diff(call.expires_at, now(), :second), 1)}
            else
              ended =
                call
                |> transition_to_ending!()
                |> cleanup_provider!(provider_cleanup)
                |> end_call!(system_expiry_subject(call), nil, "expired")

              {:expired, ended}
            end
        end
      end)
      |> unwrap()
    else
      {:error, :forbidden}
    end
  end

  def expire_call(_, _, _), do: {:error, :not_found}

  def authorize_end(conversation_id, call_id, attrs, subject)
      when is_binary(conversation_id) and is_binary(call_id) and is_map(attrs) and
             is_map(subject) do
    with %AudioCall{} = call <- scoped_call(conversation_id, call_id, subject),
         :ok <- Authorization.authorize(end_action(call.media_kind), subject, call),
         {:ok, reason} <- end_reason(attrs) do
      {:ok, call, reason}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def authorize_end(_, _, _, _), do: {:error, :not_found}

  def can_end?(%AudioCall{} = call, subject) when is_map(subject) do
    Authorization.authorize(end_action(call.media_kind), subject, call) == :ok
  end

  def can_end?(_, _), do: false

  def end_call(conversation_id, call_id, attrs, subject),
    do:
      end_call(
        conversation_id,
        call_id,
        attrs,
        subject,
        &provider_cleanup_required/1,
        nil
      )

  def end_call(conversation_id, call_id, attrs, subject, provider_cleanup)
      when is_binary(conversation_id) and is_binary(call_id) and is_map(attrs) and
             is_map(subject) and is_function(provider_cleanup, 1) do
    end_call(conversation_id, call_id, attrs, subject, provider_cleanup, nil)
  end

  def end_call(_, _, _, _, _), do: {:error, :not_found}

  def end_call(conversation_id, call_id, attrs, subject, provider_cleanup, expected_kind)
      when is_binary(conversation_id) and is_binary(call_id) and is_map(attrs) and
             is_map(subject) and is_function(provider_cleanup, 1) and
             (is_nil(expected_kind) or expected_kind in @media_kinds) do
    with {:ok, reason} <- end_reason(attrs) do
      Repo.transaction(fn ->
        call = lock_call!(conversation_id, call_id, subject)
        ensure_media_kind!(call, expected_kind)
        authorize!(end_action(call.media_kind), subject, call)

        case call.status do
          :ended ->
            call

          :ending ->
            Repo.rollback(:audio_call_ending)

          :active ->
            call
            |> transition_to_ending!()
            |> cleanup_provider!(provider_cleanup)
            |> end_call!(subject, value(subject, :user_id), reason)
        end
      end)
      |> unwrap()
    end
  end

  def end_call(_, _, _, _, _, _), do: {:error, :not_found}

  defp replace_if_expired!(call, conversation, subject, media_kind, provider_cleanup) do
    if expired?(call) do
      call
      |> transition_to_ending!()
      |> cleanup_provider!(provider_cleanup)
      |> end_call!(subject, nil, "expired")

      {create_call!(conversation, subject, media_kind), :created}
    else
      {call, :existing}
    end
  end

  defp start_locked!(conversation, subject, media_kind, provider_cleanup) do
    case active_call_for_update(conversation.tenant_id, conversation.id) do
      %AudioCall{status: :ending} ->
        Repo.rollback(:audio_call_ending)

      %AudioCall{} = call ->
        cond do
          expired?(call) ->
            replace_if_expired!(call, conversation, subject, media_kind, provider_cleanup)

          call.media_kind != media_kind ->
            Repo.rollback(:call_media_kind_conflict)

          true ->
            {call, :existing}
        end

      nil ->
        {create_call!(conversation, subject, media_kind), :created}
    end
  end

  defp create_call!(conversation, subject, media_kind) do
    timestamp = now()
    call_id = Ecto.UUID.generate()

    call =
      %AudioCall{id: call_id}
      |> AudioCall.changeset(%{
        id: call_id,
        tenant_id: conversation.tenant_id,
        conversation_id: conversation.id,
        started_by_user_id: value(subject, :user_id),
        provider_room: provider_room(call_id),
        media_kind: media_kind,
        status: :active,
        started_at: timestamp,
        expires_at: DateTime.add(timestamp, @maximum_call_seconds, :second)
      })
      |> insert_or_rollback()

    enqueue_expiry!(call)

    insert_audit!(subject, "#{media_kind}_call.start", call, %{
      conversation_id: call.conversation_id,
      media_kind: call.media_kind,
      expires_at: call.expires_at
    })

    payload = %{
      call_id: call.id,
      conversation_id: call.conversation_id,
      media_kind: call.media_kind,
      started_by_user_id: call.started_by_user_id,
      started_at: call.started_at,
      expires_at: call.expires_at
    }

    insert_event!(call, "call.started.v1", payload)
    if call.media_kind == :audio, do: insert_event!(call, "audio_call.started.v1", payload)

    call
  end

  defp end_call!(call, subject, ended_by_user_id, reason) do
    timestamp = now()

    revocation_reason = if reason == "expired", do: "call_expired", else: "call_ended"

    case revoke_for_call(call.tenant_id, call.id, revocation_reason) do
      {:ok, _count} -> :ok
      {:error, revoke_reason} -> Repo.rollback(revoke_reason)
    end

    ended =
      call
      |> AudioCall.changeset(%{
        status: :ended,
        ended_by_user_id: ended_by_user_id,
        ended_at: timestamp,
        end_reason: reason
      })
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> update_or_rollback()

    insert_audit!(subject, "#{ended.media_kind}_call.end", ended, %{
      conversation_id: ended.conversation_id,
      media_kind: ended.media_kind,
      reason: reason,
      ended_by_user_id: ended_by_user_id
    })

    payload = %{
      call_id: ended.id,
      conversation_id: ended.conversation_id,
      media_kind: ended.media_kind,
      ended_by_user_id: ended.ended_by_user_id,
      ended_at: ended.ended_at,
      end_reason: ended.end_reason
    }

    insert_event!(ended, "call.ended.v1", payload)
    if ended.media_kind == :audio, do: insert_event!(ended, "audio_call.ended.v1", payload)

    ended
  end

  defp transition_to_ending!(call) do
    call
    |> AudioCall.changeset(%{status: :ending})
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> update_or_rollback()
  end

  defp cleanup_provider!(call, provider_cleanup) do
    case provider_cleanup.(call) do
      :ok -> call
      {:error, reason} -> Repo.rollback(reason)
      _ -> Repo.rollback(:audio_provider_unavailable)
    end
  end

  defp scoped_call(conversation_id, call_id, subject) do
    Repo.get_by(AudioCall,
      id: call_id,
      tenant_id: value(subject, :tenant_id),
      conversation_id: conversation_id
    )
  end

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

  defp lock_join_authority!(conversation_id, subject) do
    lock_authority!(conversation_id, subject, "FOR SHARE")
    :ok
  end

  defp lock_start_join_authority!(conversation_id, subject) do
    lock_authority!(conversation_id, subject, "FOR UPDATE")
  end

  defp lock_authority!(conversation_id, subject, conversation_lock) do
    timestamp = now()

    Repo.one(
      from(tenant in Tenant,
        where: tenant.id == ^value(subject, :tenant_id) and tenant.status == :active,
        lock: "FOR SHARE"
      )
    ) || Repo.rollback(:forbidden)

    conversation =
      Conversation
      |> where(
        [conversation],
        conversation.id == ^conversation_id and
          conversation.tenant_id == ^value(subject, :tenant_id) and
          is_nil(conversation.archived_at)
      )
      |> lock_authority_conversation(conversation_lock)

    conversation || Repo.rollback(:forbidden)

    Repo.one(
      from(session in Session,
        where:
          session.id == ^value(subject, :session_id) and
            session.tenant_id == ^value(subject, :tenant_id) and
            session.user_id == ^value(subject, :user_id) and
            session.device_id == ^value(subject, :device_id) and is_nil(session.revoked_at) and
            session.expires_at > ^timestamp and session.absolute_expires_at > ^timestamp,
        lock: "FOR SHARE"
      )
    ) || Repo.rollback(:forbidden)

    Repo.one(
      from(membership in Membership,
        where:
          membership.tenant_id == ^value(subject, :tenant_id) and
            membership.conversation_id == ^conversation_id and
            membership.user_id == ^value(subject, :user_id) and is_nil(membership.left_at),
        lock: "FOR SHARE"
      )
    ) || Repo.rollback(:forbidden)

    conversation
  end

  defp lock_authority_conversation(query, "FOR SHARE") do
    query |> lock("FOR SHARE") |> Repo.one()
  end

  defp lock_authority_conversation(query, "FOR UPDATE") do
    query |> lock("FOR UPDATE") |> Repo.one()
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

  defp record_credential_issuance!(participant) do
    participant
    |> AudioCallParticipant.admission_changeset(%{
      credential_issued_at: now(),
      credential_issue_count: participant.credential_issue_count + 1
    })
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> update_or_rollback()
  end

  defp issue_credential!(call, participant, issuer) do
    case issuer.(call, participant) do
      {:ok, credential} ->
        record_credential_issuance!(participant)
        credential

      {:error, reason} ->
        Repo.rollback(reason)

      _ ->
        Repo.rollback(:audio_provider_unavailable)
    end
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

  defp enqueue_expiry!(call) do
    %{"call_id" => call.id, "tenant_id" => call.tenant_id}
    |> Oban.Job.new(
      worker: RuntimePorts.job_worker_name!(:audio_call_expiry),
      queue: :media,
      scheduled_at: call.expires_at,
      unique: [
        period: :infinity,
        fields: [:worker, :args],
        states: [:available, :scheduled, :executing, :retryable]
      ]
    )
    |> insert_or_rollback()
  end

  defp system_expiry_subject(call) do
    %{
      tenant_id: call.tenant_id,
      user_id: nil,
      request_id: "call-expiry:#{call.id}"
    }
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

  defp active_call_for_update(tenant_id, conversation_id) do
    Repo.one(
      from(call in AudioCall,
        where:
          call.tenant_id == ^tenant_id and call.conversation_id == ^conversation_id and
            call.status in [:active, :ending],
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_conversation!(conversation_id, subject) do
    Repo.one(
      from(conversation in Conversation,
        where:
          conversation.id == ^conversation_id and
            conversation.tenant_id == ^value(subject, :tenant_id) and
            is_nil(conversation.archived_at),
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  defp lock_call!(conversation_id, call_id, subject) do
    Repo.one(
      from(call in AudioCall,
        where:
          call.id == ^call_id and call.conversation_id == ^conversation_id and
            call.tenant_id == ^value(subject, :tenant_id),
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  defp lock_call_by_id!(call_id) do
    Repo.one(from(call in AudioCall, where: call.id == ^call_id, lock: "FOR UPDATE")) ||
      Repo.rollback(:not_found)
  end

  defp ensure_active(%AudioCall{status: :ended}), do: {:error, :audio_call_ended}
  defp ensure_active(%AudioCall{status: :ending}), do: {:error, :audio_call_ending}

  defp ensure_active(%AudioCall{} = call) do
    if expired?(call), do: {:error, :audio_call_expired}, else: :ok
  end

  defp ensure_active!(call) do
    case ensure_active(call) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp authorize_active_call(nil, _subject), do: :ok

  defp authorize_active_call(%AudioCall{} = call, subject) do
    Authorization.authorize(read_action(call.media_kind), subject, call)
  end

  defp ensure_media_kind(nil, _expected_kind), do: :ok
  defp ensure_media_kind(_call, nil), do: :ok
  defp ensure_media_kind(%AudioCall{media_kind: media_kind}, media_kind), do: :ok
  defp ensure_media_kind(%AudioCall{}, _expected_kind), do: {:error, :call_media_kind_conflict}

  defp ensure_media_kind!(call, expected_kind) do
    case ensure_media_kind(call, expected_kind) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp expired?(%AudioCall{expires_at: expires_at}),
    do: DateTime.compare(expires_at, now()) != :gt

  defp end_reason(attrs) do
    case value(attrs, :reason) || value(attrs, :end_reason) || "ended_by_user" do
      reason when is_binary(reason) ->
        reason = String.trim(reason)
        if String.length(reason) in 3..120, do: {:ok, reason}, else: {:error, :invalid_end_reason}

      _ ->
        {:error, :invalid_end_reason}
    end
  end

  defp insert_audit!(subject, action, call, metadata) do
    Audit.record(%{
      tenant_id: call.tenant_id,
      actor_user_id: value(subject, :user_id),
      action: action,
      resource_type: "#{call.media_kind}_call",
      resource_id: call.id,
      metadata: metadata,
      request_id: value(subject, :request_id)
    })
    |> audit_or_rollback()
  end

  defp audit_or_rollback({:ok, event}), do: event
  defp audit_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp insert_event!(call, event_type, payload) do
    Outbox.insert_and_enqueue!(%{
      tenant_id: call.tenant_id,
      event_type: event_type,
      aggregate_type:
        if(String.starts_with?(event_type, "audio_call."), do: "audio_call", else: "call"),
      aggregate_id: call.id,
      payload: payload,
      available_at: now()
    })
  end

  defp authorize!(action, subject, resource) do
    case Authorization.authorize(action, subject, resource) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
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

  defp unwrap_start({:ok, {call, status}}), do: {:ok, call, status}
  defp unwrap_start({:error, reason}), do: {:error, reason}

  defp unwrap_start_join({:ok, {call, status, credential}}),
    do: {:ok, call, status, credential}

  defp unwrap_start_join({:error, reason}), do: {:error, reason}
  defp unwrap_join({:ok, {call, credential}}), do: {:ok, call, credential}
  defp unwrap_join({:error, reason}), do: {:error, reason}
  defp unwrap({:ok, result}), do: {:ok, result}
  defp unwrap({:error, reason}), do: {:error, reason}

  defp provider_cleanup_required(_call), do: {:error, :audio_provider_unavailable}

  defp read_action(:audio), do: :read_audio_call
  defp read_action(:video), do: :read_video_call
  defp start_action(:audio), do: :start_audio_call
  defp start_action(:video), do: :start_video_call
  defp join_action(:audio), do: :join_audio_call
  defp join_action(:video), do: :join_video_call
  defp end_action(:audio), do: :end_audio_call
  defp end_action(:video), do: :end_video_call

  defp provider_room(call_id), do: "kc_call_" <> String.replace(call_id, "-", "")
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
