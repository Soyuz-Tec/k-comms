defmodule CommsCore.AudioCalls.Artifacts do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Accounts, Audit, Conversations, Repo, RuntimePorts}

  alias CommsCore.AudioCalls.{
    AudioCall,
    AudioCallParticipant,
    AuthorizationPolicy,
    ArtifactErasurePlan,
    ArtifactProtectionPort,
    ArtifactProviderPort,
    ArtifactProviderRequest,
    ArtifactStorageObject,
    ArtifactStoragePort,
    ArtifactTranscriptionPort,
    ArtifactTranscriptionRequest,
    ArtifactTranscriptSegment,
    ArtifactView
  }

  alias CommsCore.AudioCalls.Artifacts.{
    Artifact,
    Consent,
    DerivedAuthority,
    ProviderEvent,
    Segment,
    Summary,
    Summaries
  }

  @capturing [:starting, :recording, :stopping]

  @doc false
  @spec rollback_hazard_count() :: non_neg_integer()
  def rollback_hazard_count() do
    # A deleted state without the worker's completed-erasure timestamp is not
    # proof of physical cleanup. Count stored transcript content independently,
    # including inconsistent metadata, so rollback cannot strand its erasure.
    require_rollback_table!("call_artifacts")
    require_rollback_table!("call_artifact_segments")

    metadata =
      Repo.aggregate(
        from(a in Artifact,
          where: a.status != :deleted or is_nil(a.deleted_at)
        ),
        :count,
        :id
      )

    segments = Repo.aggregate(Segment, :count, :id)
    rollback_count!(metadata) + rollback_count!(segments)
  end

  defp require_rollback_table!(table) do
    case Repo.query!("SELECT to_regclass($1) IS NOT NULL", ["public." <> table]).rows do
      [[true]] -> :ok
      _ -> raise "Calls artifact rollback inventory unavailable"
    end
  end

  defp rollback_count!(count) when is_integer(count) and count >= 0, do: count
  defp rollback_count!(_), do: raise("Invalid Calls artifact rollback hazard count")

  def capabilities(subject) do
    enabled = policy_enabled?(subject)

    %{
      recording: enabled and ArtifactProviderPort.configured?(),
      recording_reason:
        if(enabled,
          do: "provider_configuration_required",
          else: "workspace_privacy_opt_in_required"
        ),
      participant_consent_required: true,
      persistent_transcript: enabled and ArtifactTranscriptionPort.configured?(),
      persistent_transcript_reason: "qualified_transcription_provider_required",
      captions: "provider_events_only",
      recognition_mode: "post_recording",
      explicit_summary: enabled and Summaries.enabled?(value(subject, :tenant_id)),
      summary_consent_required: true,
      summary_post_call_only: true,
      automatic_capture: false
    }
  end

  def list(conversation_id, call_id, subject) do
    with {:ok, call} <- authorized_call(conversation_id, call_id, subject) do
      artifacts =
        Repo.all(
          from(a in Artifact,
            where:
              a.tenant_id == ^call.tenant_id and a.call_id == ^call.id and
                a.status != :deleted and
                ((a.expires_at > ^now() and is_nil(a.erasure_requested_at)) or
                   a.status in ^@capturing),
            order_by: [desc: a.inserted_at],
            limit: 100
          )
        )

      artifacts =
        if guest?(subject),
          do:
            Enum.filter(
              artifacts,
              &(&1.status in [:pending_consent, :starting, :recording, :stopping])
            ),
          else: artifacts

      {:ok,
       %{
         artifacts: Enum.map(artifacts, &view(&1, subject, call)),
         capabilities: capabilities(subject)
       }}
    end
  end

  def search(subject, params) do
    if guest?(subject), do: {:error, :forbidden}, else: search_member(subject, params)
  end

  defp search_member(subject, params) do
    with {:ok, grant} <- Accounts.access_grant(subject),
         {:ok, conversation_id} <- optional_uuid(value(params, :conversation_id)) do
      authorization_query = Conversations.active_membership_authorization_query(grant)
      limit = min(max(integer(value(params, :limit), 20), 1), 100)

      query =
        from(a in Artifact,
          as: :artifact,
          join: authorization in subquery(authorization_query),
          on: authorization.conversation_id == a.conversation_id,
          where:
            a.tenant_id == ^grant.tenant_id and a.status == :available and a.expires_at > ^now() and
              is_nil(a.erasure_requested_at),
          order_by: [desc: a.inserted_at, desc: a.id],
          limit: ^limit
        )

      query =
        if conversation_id,
          do: where(query, [a], a.conversation_id == ^conversation_id),
          else: query

      q = value(params, :q)

      query =
        if is_binary(q) and String.trim(q) != "" do
          pattern = "%" <> (q |> String.trim() |> String.slice(0, 500) |> escape_like()) <> "%"

          where(
            query,
            [a],
            ilike(fragment("?::text", a.kind), ^pattern) or
              exists(
                from(s in Segment,
                  where:
                    s.tenant_id == ^grant.tenant_id and
                      s.artifact_id == parent_as(:artifact).id and ilike(s.text, ^pattern),
                  select: 1
                )
              )
          )
        else
          query
        end

      artifacts = Repo.all(query)
      {:ok, Enum.map(artifacts, &view(&1, subject, nil))}
    end
  end

  def request(conversation_id, call_id, attrs, subject) when is_map(attrs) do
    case value(attrs, :kind) do
      kind when kind in [:transcript, "transcript"] ->
        request_transcript(conversation_id, call_id, attrs, subject)

      kind when kind in [:summary, "summary"] ->
        Summaries.request(conversation_id, call_id, attrs, subject)

      _ ->
        request_recording(conversation_id, call_id, attrs, subject)
    end
  end

  defp request_recording(conversation_id, call_id, attrs, subject) do
    transaction(fn ->
      if protection!(value(subject, :tenant_id), conversation_id, []).capture_blocked,
        do: Repo.rollback(:artifact_erasure_pending)

      call = locked_call!(conversation_id, call_id, subject)
      manage!(call, subject)
      active!(call)
      ensure_livekit_capture!()
      if not policy_enabled?(subject), do: Repo.rollback(:recording_disabled)
      if not ArtifactProviderPort.configured?(), do: Repo.rollback(:artifact_provider_unavailable)

      if value(attrs, :kind) not in [nil, :recording, "recording"],
        do: Repo.rollback(:transcription_unavailable)

      summary_requested = value(attrs, :summary_requested) == true

      if summary_requested and not Summaries.enabled?(call.tenant_id),
        do: Repo.rollback(:summarization_unavailable)

      if value(attrs, :summary_requested) not in [nil, false, true],
        do: Repo.rollback(:invalid_summary_consent)

      key = value(attrs, :idempotency_key)

      if not is_binary(key) or byte_size(key) not in 8..120,
        do: Repo.rollback(:idempotency_key_required)

      case Repo.get_by(Artifact,
             tenant_id: call.tenant_id,
             call_id: call.id,
             idempotency_key: key
           ) do
        %Artifact{kind: :recording} = existing ->
          if existing.summary_requested != summary_requested,
            do: Repo.rollback(:idempotency_conflict)

          view(existing, subject, call)

        %Artifact{} ->
          Repo.rollback(:idempotency_conflict)

        nil ->
          participants = admitted(call)

          if participants == [] or
               Enum.all?(participants, &(&1.session_id != value(subject, :session_id))),
             do: Repo.rollback(:recording_requires_admission)

          protection =
            protection!(
              call.tenant_id,
              call.conversation_id,
              Enum.map(participants, & &1.user_id)
            )

          if protection.capture_blocked, do: Repo.rollback(:artifact_erasure_pending)
          id = Ecto.UUID.generate()

          artifact =
            insert!(
              Artifact.changeset(%Artifact{id: id}, %{
                tenant_id: call.tenant_id,
                conversation_id: call.conversation_id,
                call_id: call.id,
                meeting_id: meeting_id(call),
                requested_by_user_id: value(subject, :user_id),
                requested_by_device_id: value(subject, :device_id),
                requested_by_session_id: value(subject, :session_id),
                kind: :recording,
                summary_requested: summary_requested,
                provider_room: call.provider_room,
                object_key: "#{call.tenant_id}/meeting-artifacts/#{call.id}/#{id}.mp4",
                content_type: "video/mp4",
                expires_at: DateTime.add(now(), protection.retention_days * 86_400, :second),
                idempotency_key: key,
                status: :pending_consent
              })
            )

          snapshot_consents!(artifact, participants)
          audit!(artifact, subject, "call.recording_requested")
          enqueue!(artifact)
          view(artifact, subject, call)
      end
    end)
  end

  defp request_transcript(conversation_id, call_id, attrs, subject) do
    transaction(fn ->
      if protection!(value(subject, :tenant_id), conversation_id, []).capture_blocked,
        do: Repo.rollback(:artifact_erasure_pending)

      call = locked_call!(conversation_id, call_id, subject)
      manage!(call, subject)

      if not policy_enabled?(subject) or not ArtifactTranscriptionPort.configured?(),
        do: Repo.rollback(:transcription_unavailable)

      source = locked_artifact!(call, value(attrs, :source_artifact_id))
      if protection!(source).capture_blocked, do: Repo.rollback(:artifact_erasure_pending)

      if source.kind != :recording or source.status != :available or
           not is_nil(source.erasure_requested_at) or
           DateTime.compare(source.expires_at, now()) != :gt,
         do: Repo.rollback(:artifact_not_available)

      consents = Repo.all(from(c in Consent, where: c.artifact_id == ^source.id))

      if consents == [] or Enum.any?(consents, &(!&1.accepted)),
        do: Repo.rollback(:recording_consent_required)

      key = value(attrs, :idempotency_key)

      if not is_binary(key) or byte_size(key) not in 8..120,
        do: Repo.rollback(:idempotency_key_required)

      case Repo.get_by(Artifact,
             tenant_id: source.tenant_id,
             call_id: call.id,
             idempotency_key: key
           ) do
        %Artifact{kind: :transcript, source_artifact_id: source_id} = existing
        when source_id == source.id ->
          view(existing, subject, call)

        %Artifact{} ->
          Repo.rollback(:idempotency_conflict)

        nil ->
          id = Ecto.UUID.generate()

          artifact =
            insert!(
              Artifact.changeset(%Artifact{id: id}, %{
                tenant_id: source.tenant_id,
                conversation_id: source.conversation_id,
                call_id: source.call_id,
                meeting_id: source.meeting_id,
                source_artifact_id: source.id,
                requested_by_user_id: value(subject, :user_id),
                requested_by_device_id: value(subject, :device_id),
                requested_by_session_id: value(subject, :session_id),
                summary_requested: source.summary_requested,
                kind: :transcript,
                status: :processing,
                provider_room: source.provider_room,
                object_key: "#{source.tenant_id}/meeting-artifacts/#{source.call_id}/#{id}.json",
                content_type: "application/json",
                expires_at: source.expires_at,
                idempotency_key: key
              })
            )

          Enum.each(consents, fn c ->
            insert!(
              Consent.changeset(%Consent{}, %{
                tenant_id: c.tenant_id,
                artifact_id: id,
                participant_id: c.participant_id,
                user_id: c.user_id,
                session_id: c.session_id,
                accepted: true,
                summary_accepted: c.summary_accepted,
                summary_policy_version: c.summary_policy_version,
                summary_decided_at: c.summary_decided_at,
                decided_at: c.decided_at
              })
            )
          end)

          enqueue!(artifact)
          audit!(artifact, subject, "call.transcript_requested")
          view(artifact, subject, call)
      end
    end)
  end

  def consent(conversation_id, call_id, artifact_id, accepted, subject)
      when is_boolean(accepted) do
    transaction(fn ->
      protection!(value(subject, :tenant_id), conversation_id, [])
      call = locked_call!(conversation_id, call_id, subject)
      if accepted, do: active!(call)
      artifact = locked_artifact!(call, artifact_id)

      if artifact.status not in [:pending_consent, :starting, :recording, :stopping],
        do: Repo.rollback(:artifact_not_capturing)

      participant =
        Enum.find(admitted(call), &(&1.session_id == value(subject, :session_id))) ||
          Repo.rollback(:forbidden)

      consent =
        Repo.get_by(Consent, artifact_id: artifact.id, participant_id: participant.id) ||
          insert!(Consent.changeset(%Consent{}, consent_attrs(artifact, participant)))

      update!(Consent.changeset(consent, %{accepted: accepted, decided_at: now()}))
      if not accepted, do: Summaries.invalidate(root_artifact_for_summary(artifact))

      artifact =
        if not accepted and artifact.status in @capturing,
          do: stop!(artifact, "consent_withdrawn"),
          else: artifact

      audit!(
        artifact,
        subject,
        if(accepted,
          do: "call.recording_consent_accepted",
          else: "call.recording_consent_declined"
        )
      )

      view(artifact, subject, call)
    end)
  end

  def consent(_, _, _, _, _), do: {:error, :invalid_artifact_consent}

  @doc false
  def summary_metadata(artifact, subject, call), do: view(artifact, subject, call)

  def summary(conversation_id, call_id, id, subject),
    do: Summaries.get(conversation_id, call_id, id, subject)

  def summary_consent(conversation_id, call_id, id, attrs, subject),
    do: Summaries.consent(conversation_id, call_id, id, attrs, subject)

  def rollback_summary_hazard_count(), do: Summaries.rollback_hazard_count()

  def start(conversation_id, call_id, artifact_id, subject) do
    transaction(fn ->
      protection!(value(subject, :tenant_id), conversation_id, [])
      call = locked_call!(conversation_id, call_id, subject)
      manage!(call, subject)
      active!(call)
      ensure_livekit_capture!()
      if not policy_enabled?(subject), do: Repo.rollback(:recording_disabled)
      artifact = locked_artifact!(call, artifact_id)

      if protection!(artifact).capture_blocked or not is_nil(artifact.erasure_requested_at),
        do: Repo.rollback(:artifact_erasure_pending)

      if artifact.status == :pending_consent do
        ensure_all_consented!(artifact, admitted(call))
        updated = update!(Artifact.changeset(artifact, %{status: :starting}))
        enqueue!(updated)
        audit!(updated, subject, "call.recording_start_requested")
        view(updated, subject, call)
      else
        if artifact.status in [:starting, :recording],
          do: view(artifact, subject, call),
          else: Repo.rollback(:artifact_not_startable)
      end
    end)
  end

  def stop(conversation_id, call_id, artifact_id, subject) do
    transaction(fn ->
      call = locked_call!(conversation_id, call_id, subject)
      manage!(call, subject)
      artifact = locked_artifact!(call, artifact_id)

      artifact =
        case artifact.status do
          :pending_consent ->
            update!(
              Artifact.changeset(artifact, %{
                status: :failed,
                failure_code: "cancelled",
                ended_at: now()
              })
            )

          status when status in @capturing ->
            stop!(artifact, "host_stopped")

          _ ->
            artifact
        end

      audit!(artifact, subject, "call.recording_stop_requested")
      view(artifact, subject, call)
    end)
  end

  # Called by Calls lifecycle before minting a NEW admission. Existing consented
  # sessions may refresh credentials; new sessions wait until capture has ended.
  def authorize_admission(tenant_id, call_id, session_id) do
    artifacts =
      Repo.all(
        from(a in Artifact,
          where: a.tenant_id == ^tenant_id and a.call_id == ^call_id and a.status in ^@capturing
        )
      )

    if Enum.all?(artifacts, fn artifact ->
         artifact.status == :recording and
           Repo.exists?(
             from(c in Consent,
               where:
                 c.artifact_id == ^artifact.id and c.session_id == ^session_id and
                   c.accepted == true
             )
           )
       end), do: :ok, else: {:error, :recording_consent_admission_blocked}
  end

  def stop_for_access_change(tenant_id, call_ids) when is_list(call_ids) do
    if Repo.in_transaction?() do
      artifacts =
        Repo.all(
          from(a in Artifact,
            where:
              a.tenant_id == ^tenant_id and a.call_id in ^call_ids and a.status in ^@capturing,
            lock: "FOR UPDATE"
          )
        )

      Enum.each(artifacts, &stop!(&1, "access_changed"))
      :ok
    else
      {:error, :transaction_required}
    end
  end

  def playback(conversation_id, call_id, artifact_id, subject) do
    transaction(fn ->
      if guest?(subject), do: Repo.rollback(:forbidden)
      call = locked_call!(conversation_id, call_id, subject)
      artifact = locked_artifact!(call, artifact_id)

      if artifact.kind != :recording or artifact.status != :available or
           not is_nil(artifact.erasure_requested_at) or
           DateTime.compare(artifact.expires_at, now()) != :gt,
         do: Repo.rollback(:artifact_not_available)

      case ArtifactStoragePort.download(storage_object(artifact)) do
        {:ok, download} ->
          audit!(artifact, subject, "call.artifact_playback_authorized")
          %{artifact: view(artifact, subject, call), download: download}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  def transcript(conversation_id, call_id, artifact_id, subject) do
    transaction(fn ->
      if guest?(subject), do: Repo.rollback(:forbidden)
      call = locked_call!(conversation_id, call_id, subject)
      artifact = locked_artifact!(call, artifact_id)

      if artifact.kind != :transcript or artifact.status != :available or
           not is_nil(artifact.erasure_requested_at) or
           DateTime.compare(artifact.expires_at, now()) != :gt,
         do: Repo.rollback(:artifact_not_available)

      segments =
        Repo.all(
          from(s in Segment,
            where: s.tenant_id == ^artifact.tenant_id and s.artifact_id == ^artifact.id,
            order_by: [asc: s.sequence],
            limit: 10_000
          )
        )
        |> Enum.map(
          &%ArtifactTranscriptSegment{
            sequence: &1.sequence,
            start_ms: &1.start_ms,
            end_ms: &1.end_ms,
            text: &1.text
          }
        )

      audit!(artifact, subject, "call.transcript_read")
      %{artifact: view(artifact, subject, call), segments: segments}
    end)
  end

  def delete(conversation_id, call_id, artifact_id, subject) do
    transaction(fn ->
      protection!(value(subject, :tenant_id), conversation_id, [])
      call = locked_call!(conversation_id, call_id, subject)
      manage!(call, subject)
      artifact = locked_artifact!(call, artifact_id)
      if artifact.status in @capturing, do: Repo.rollback(:recording_must_stop_before_deletion)
      if artifact.status == :processing, do: Repo.rollback(:artifact_processing)
      if protection!(artifact).held, do: Repo.rollback(:artifact_legal_hold)

      if artifact.kind in [:recording, :transcript] do
        direct_ids =
          Repo.all(
            from(a in Artifact,
              where: a.tenant_id == ^artifact.tenant_id and a.source_artifact_id == ^artifact.id,
              select: a.id
            )
          )

        children =
          Repo.all(
            from(a in Artifact,
              where:
                a.tenant_id == ^artifact.tenant_id and
                  (a.source_artifact_id == ^artifact.id or a.source_artifact_id in ^direct_ids) and
                  a.status != :deleted,
              order_by: [
                asc:
                  fragment(
                    "CASE ? WHEN 'recording' THEN 0 WHEN 'transcript' THEN 1 ELSE 2 END",
                    a.kind
                  ),
                asc: a.id
              ],
              lock: "FOR UPDATE"
            )
          )

        if Enum.any?(children, &(&1.status == :processing)),
          do: Repo.rollback(:artifact_processing)

        Enum.each(children, fn child ->
          if protection!(child).held, do: Repo.rollback(:artifact_legal_hold)
          enqueue!(update!(Artifact.changeset(child, %{status: :deleting})))
        end)
      end

      artifact =
        if artifact.status == :deleted,
          do: artifact,
          else: update!(Artifact.changeset(artifact, %{status: :deleting}))

      enqueue!(artifact)
      audit!(artifact, subject, "call.artifact_deletion_requested")
      view(artifact, subject, call)
    end)
  end

  def handle_callback(body, authorization) do
    with {:ok, event} <- ArtifactProviderPort.verify_callback(body, authorization),
         :ok <- valid_callback(event) do
      transaction(fn ->
        query =
          from(a in Artifact, where: a.provider_room == ^event.provider_room, lock: "FOR UPDATE")

        query =
          if is_binary(event.object_key) do
            where(
              query,
              [a],
              a.object_key == ^event.object_key and
                (a.provider_job_id == ^event.provider_job_id or
                   (is_nil(a.provider_job_id) and a.status in [:starting, :stopping]))
            )
          else
            # Nonterminal Egress updates omit file output. They may only update a
            # previously bound exact job/room; adoption still requires its output.
            where(query, [a], a.provider_job_id == ^event.provider_job_id)
          end

        artifact = Repo.one(query) || Repo.rollback(:not_found)

        digest = Base.encode16(:crypto.hash(:sha256, body), case: :lower)

        case Repo.get_by(ProviderEvent, event_id: event.event_id) do
          %ProviderEvent{body_sha256: ^digest, artifact_id: id} when id == artifact.id ->
            :replayed

          %ProviderEvent{} ->
            Repo.rollback(:artifact_callback_conflict)

          nil ->
            insert!(
              ProviderEvent.changeset(%ProviderEvent{}, %{
                tenant_id: artifact.tenant_id,
                artifact_id: artifact.id,
                event_id: event.event_id,
                body_sha256: digest
              })
            )

            if artifact.status not in [:available, :deleted, :deleting, :failed] do
              attrs =
                case event.state do
                  :available ->
                    %{
                      status: :processing,
                      provider_job_id: event.provider_job_id,
                      byte_size: event.byte_size,
                      ended_at: now()
                    }

                  :failed ->
                    %{
                      status: :failed,
                      provider_job_id: event.provider_job_id,
                      failure_code: "provider_failed",
                      ended_at: now()
                    }

                  _ ->
                    %{provider_job_id: event.provider_job_id}
                end

              updated = update!(Artifact.changeset(artifact, attrs))
              enqueue!(updated)
            end

            :accepted
        end
      end)
    end
  end

  def process(artifact_id, caller) do
    artifact = Repo.get(Artifact, artifact_id)
    kind = if artifact && artifact.kind == :summary, do: :call_summary, else: :call_artifact

    cond do
      is_nil(artifact) and RuntimePorts.authorized_job_worker?(:call_summary, caller) ->
        {:error, :not_found}

      RuntimePorts.authorized_job_worker?(kind, caller) ->
        with {:ok, action} <- claim_action(artifact_id), do: perform_action(action)

      true ->
        {:error, :forbidden}
    end
  end

  def reconcile(caller) do
    if RuntimePorts.authorized_job_worker?(:call_artifact_reconciler, caller) do
      deadline = System.monotonic_time(:millisecond) + 15_000

      ids =
        Repo.all(
          from(a in Artifact,
            where:
              a.status in [
                :pending_consent,
                :starting,
                :recording,
                :stopping,
                :processing,
                :deleting
              ] or
                (a.status != :deleted and
                   (a.expires_at <= ^now() or not is_nil(a.erasure_requested_at))),
            order_by: [asc_nulls_first: a.last_reconciled_at, asc: a.id],
            limit: 100,
            select: a.id
          )
        )

      # Metadata reconciliation holds exactly one artifact lock at a time. A
      # batch ordered by last_reconciled_at/id could otherwise retain a derived
      # row and then wait on its source while an effect holds source -> derived.
      Enum.reduce_while(ids, {:ok, 0}, fn id, {:ok, count} ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          {:halt, {:ok, count}}
        else
          case transaction(
                 fn ->
                   artifact = lock_id!(id)
                   enqueue!(artifact)
                   update!(Artifact.changeset(artifact, %{last_reconciled_at: now()}))
                 end,
                 timeout: remaining
               ) do
            {:ok, _} -> {:cont, {:ok, count + 1}}
            {:error, _} = error -> {:halt, error}
          end
        end
      end)
    else
      {:error, :forbidden}
    end
  end

  defp claim_action(id) do
    transaction(fn ->
      snapshot = Repo.get(Artifact, id) || Repo.rollback(:not_found)
      protection = protection!(snapshot)

      artifact =
        Repo.one(from(a in Artifact, where: a.id == ^id, lock: "FOR UPDATE")) ||
          Repo.rollback(:not_found)

      call = Repo.get!(AudioCall, artifact.call_id)
      expired = DateTime.compare(artifact.expires_at, now()) != :gt

      artifact =
        if artifact.status == :pending_consent and
             (call.status != :active or DateTime.compare(call.expires_at, now()) != :gt or
                not policy_enabled?(%{tenant_id: artifact.tenant_id})) do
          update!(
            Artifact.changeset(artifact, %{
              status: :failed,
              failure_code: "cancelled",
              ended_at: now()
            })
          )
        else
          artifact
        end

      artifact =
        if artifact.kind == :transcript and artifact.status == :processing and
             (expired or protection.capture_blocked or
                not policy_enabled?(%{tenant_id: artifact.tenant_id})) do
          update!(
            Artifact.changeset(artifact, %{
              status: :failed,
              failure_code: "transcription_authorization_changed",
              ended_at: now()
            })
          )
        else
          artifact
        end

      artifact =
        cond do
          artifact.status == :stopping and is_nil(artifact.provider_start_claimed_at) and
              is_nil(artifact.provider_job_id) ->
            update!(Artifact.changeset(artifact, %{status: :failed, ended_at: now()}))

          artifact.status in @capturing and
              (call.status != :active or DateTime.compare(call.expires_at, now()) != :gt or
                 expired or
                 not is_nil(artifact.erasure_requested_at) or protection.capture_blocked or
                 (artifact.status == :recording and
                    not current_participant_access?(admitted(call))) or
                 not policy_enabled?(%{tenant_id: artifact.tenant_id}) or
                 not all_consented?(artifact, admitted(call))) ->
            stop!(artifact, "capture_authorization_changed")

          (expired or not is_nil(artifact.erasure_requested_at)) and not protection.held and
              artifact.status not in (@capturing ++ [:deleted]) ->
            update!(Artifact.changeset(artifact, %{status: :deleting}))

          true ->
            artifact
        end

      case artifact.status do
        :starting ->
          if is_nil(artifact.provider_start_claimed_at) do
            artifact = update!(Artifact.changeset(artifact, %{provider_start_claimed_at: now()}))
            {:start, provider_request(artifact)}
          else
            {:reconcile, provider_request(artifact)}
          end

        :recording ->
          {:reconcile, provider_request(artifact)}

        :stopping ->
          {:stop, provider_request(artifact)}

        :processing ->
          if artifact.kind == :summary do
            {:summarize, artifact.id}
          else
            if artifact.kind == :transcript do
              source =
                Repo.get_by(Artifact,
                  id: artifact.source_artifact_id,
                  tenant_id: artifact.tenant_id,
                  kind: :recording
                ) || Repo.rollback(:artifact_not_available)

              if source.status != :available or expired or
                   not policy_enabled?(%{tenant_id: artifact.tenant_id}),
                 do: Repo.rollback(:artifact_not_available)

              {:transcribe,
               %ArtifactTranscriptionRequest{
                 tenant_id: artifact.tenant_id,
                 artifact_id: artifact.id,
                 source_artifact_id: source.id,
                 object: storage_object(source)
               }}
            else
              if is_integer(artifact.byte_size),
                do: {:verify, artifact},
                else: {:reconcile, provider_request(artifact)}
            end
          end

        :deleting ->
          if protection.held, do: {:held, artifact.id}, else: {:delete, artifact.id}

        _ ->
          :idle
      end
    end)
  end

  defp perform_action({:summarize, id}), do: Summaries.process(id)

  defp perform_action(:idle), do: {:ok, :idle}
  defp perform_action({:held, _}), do: {:ok, :held}

  defp perform_action({operation, request}) when operation in [:start, :stop, :reconcile] do
    result =
      case operation do
        :start ->
          start_with_current_consent(request)

        :stop ->
          case ArtifactProviderPort.reconcile(request) do
            {:ok, %{state: :recording} = receipt} ->
              ArtifactProviderPort.stop(%ArtifactProviderRequest{
                request
                | provider_job_id: receipt.provider_job_id
              })

            {:ok, receipt} ->
              {:ok, receipt}

            {:error, _} = error ->
              error
          end

        :reconcile ->
          ArtifactProviderPort.reconcile(request)
      end

    case result do
      {:ok, receipt} ->
        transaction(fn ->
          artifact = lock_id!(request.artifact_id)

          if artifact.status not in [:deleted, :available, :deleting, :failed] do
            attrs = %{provider_job_id: receipt.provider_job_id}

            attrs =
              cond do
                receipt.state == :available ->
                  Map.merge(
                    attrs,
                    %{status: :processing, ended_at: now()} |> maybe_put_size(receipt.byte_size)
                  )

                receipt.state == :failed ->
                  Map.merge(attrs, %{
                    status: :failed,
                    failure_code: "provider_failed",
                    ended_at: now()
                  })

                artifact.status == :stopping ->
                  attrs

                receipt.state == :recording and artifact.status == :starting ->
                  Map.merge(attrs, %{status: :recording, started_at: now()})

                receipt.state == :processing and artifact.status in [:starting, :recording] ->
                  Map.merge(attrs, %{status: :stopping})

                true ->
                  attrs
              end

            updated = update!(Artifact.changeset(artifact, attrs))
            if updated.status in [:stopping, :processing], do: enqueue!(updated)
          end

          :provider_updated
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp perform_action({:verify, artifact}) do
    with {:ok, verified} <- ArtifactStoragePort.verify(storage_object(artifact)) do
      transaction(fn ->
        artifact = lock_id!(artifact.id)

        if artifact.status == :processing do
          update!(
            Artifact.changeset(artifact, %{
              status: :available,
              failure_code: nil,
              object_version_id: verified.object_version_id,
              object_etag: verified.object_etag,
              checksum_sha256: verified.checksum_sha256
            })
          )

          system_audit!(artifact, "call.artifact_available")
        end

        :verified
      end)
    end
  end

  defp perform_action({:transcribe, request}) do
    effect_deadline = System.monotonic_time(:millisecond) + 150_000

    transaction(
      fn ->
        snapshot = Repo.get(Artifact, request.artifact_id) || Repo.rollback(:not_found)
        protection = protection!(snapshot)

        subject = %{
          tenant_id: snapshot.tenant_id,
          user_id: snapshot.requested_by_user_id,
          device_id: snapshot.requested_by_device_id,
          session_id: snapshot.requested_by_session_id
        }

        source_snapshot = Repo.get!(Artifact, request.source_artifact_id)

        retained_authority =
          DerivedAuthority.lock(
            source_snapshot,
            subject,
            System.monotonic_time(:millisecond) + 15_000
          )

        original_subjects =
          case retained_authority do
            {:ok, {_, subjects}} -> subjects
            _ -> []
          end

        access = AuthorizationPolicy.lock_access(subject, snapshot.conversation_id, :share)

        call =
          Repo.one!(
            from(c in AudioCall,
              where: c.tenant_id == ^snapshot.tenant_id and c.id == ^snapshot.call_id,
              lock: "FOR UPDATE"
            )
          )

        # Use the same source-before-derived order as source deletion. Keep the
        # bounded provider effect inside these locks so erasure/withdrawal cannot
        # commit between the final authorization and sending private media.
        source = lock_id!(request.source_artifact_id)
        artifact = lock_id!(request.artifact_id)

        consents =
          Repo.all(
            from(c in Consent,
              where: c.tenant_id == ^source.tenant_id and c.artifact_id == ^source.id
            )
          )

        effect_budget_available = effect_budget_available?(effect_deadline, 130_000)

        authorized =
          effect_budget_available and match?({:ok, _}, retained_authority) and
            match?({:ok, _}, access) and source.call_id == call.id and
            source.status == :available and is_nil(source.erasure_requested_at) and
            source.object_version_id == request.object.object_version_id and
            source.checksum_sha256 == request.object.checksum_sha256 and
            DateTime.compare(source.expires_at, now()) == :gt and
            DateTime.compare(artifact.expires_at, now()) == :gt and
            is_nil(artifact.erasure_requested_at) and
            not protection.capture_blocked and policy_enabled?(%{tenant_id: artifact.tenant_id}) and
            ArtifactTranscriptionPort.configured?() and
            consents != [] and Enum.all?(consents, & &1.accepted) and
            DerivedAuthority.current?([subject | original_subjects], snapshot.conversation_id)

        cond do
          artifact.status != :processing ->
            :idle

          not authorized ->
            update!(
              Artifact.changeset(artifact, %{
                status: :failed,
                failure_code:
                  if(effect_budget_available,
                    do: "transcription_authorization_changed",
                    else: "transcription_budget_exhausted"
                  ),
                ended_at: now()
              })
            )

            :transcription_cancelled

          true ->
            case ArtifactTranscriptionPort.transcribe(request) do
              {:ok, transcript} ->
                if DateTime.compare(artifact.expires_at, now()) != :gt or
                     not DerivedAuthority.current?(
                       [subject | original_subjects],
                       snapshot.conversation_id
                     ) or
                     not policy_enabled?(%{tenant_id: artifact.tenant_id}),
                   do: Repo.rollback(:artifact_not_available)

                Repo.delete_all(
                  from(s in Segment,
                    where: s.artifact_id == ^artifact.id and s.tenant_id == ^artifact.tenant_id
                  )
                )

                Enum.each(transcript.segments, fn segment ->
                  insert!(
                    Segment.changeset(%Segment{}, %{
                      tenant_id: artifact.tenant_id,
                      artifact_id: artifact.id,
                      sequence: segment.sequence,
                      start_ms: segment.start_ms,
                      end_ms: segment.end_ms,
                      text: segment.text
                    })
                  )
                end)

                update!(
                  Artifact.changeset(artifact, %{
                    status: :available,
                    failure_code: nil,
                    transcript_language: transcript.language,
                    recognition_provider_id: transcript.provider_id,
                    recognition_model_sha256: transcript.model_sha256,
                    recognition_source_sha256: transcript.source_sha256,
                    ended_at: now()
                  })
                )

                system_audit!(artifact, "call.transcript_available")
                :transcribed

              {:error, reason}
              when reason in [
                     :invalid_artifact_transcription_request,
                     :invalid_artifact_transcript,
                     :artifact_transcription_contract_invalid
                   ] ->
                update!(
                  Artifact.changeset(artifact, %{
                    status: :failed,
                    failure_code: "transcription_source_or_result_invalid",
                    ended_at: now()
                  })
                )

                system_audit!(artifact, "call.transcript_failed")
                :transcription_failed

              {:error, reason} ->
                Repo.rollback(reason)
            end
        end
      end,
      timeout: 150_000
    )
  end

  defp perform_action({:delete, id}) do
    # Keep the governance tenant lock through bounded storage deletion: a hold
    # cannot commit between the final check and the destructive provider call.
    initial = Repo.get(Artifact, id)
    transaction_timeout = if initial && initial.kind == :recording, do: 90_000, else: 15_000
    effect_deadline = System.monotonic_time(:millisecond) + transaction_timeout

    transaction(
      fn ->
        snapshot = Repo.get(Artifact, id) || Repo.rollback(:not_found)
        if protection!(snapshot).held, do: Repo.rollback(:artifact_legal_hold)
        artifact = lock_id!(id)

        if artifact.status == :deleting do
          result =
            if artifact.kind == :summary do
              Repo.delete_all(
                from(s in Summary,
                  where: s.tenant_id == ^artifact.tenant_id and s.artifact_id == ^artifact.id
                )
              )

              :ok
            else
              if artifact.kind == :transcript do
                Repo.delete_all(
                  from(s in Segment,
                    where: s.tenant_id == ^artifact.tenant_id and s.artifact_id == ^artifact.id
                  )
                )

                :ok
              else
                if not effect_budget_available?(effect_deadline, 65_000),
                  do: Repo.rollback(:artifact_processing_budget_exhausted)

                ArtifactStoragePort.delete(storage_object(artifact))
              end
            end

          case result do
            :ok ->
              update!(Artifact.changeset(artifact, %{status: :deleted, deleted_at: now()}))
              system_audit!(artifact, "call.artifact_deleted")
              :deleted

            {:error, reason} ->
              Repo.rollback(reason)
          end
        else
          :idle
        end
      end,
      timeout: transaction_timeout
    )
  end

  defp start_with_current_consent(request) do
    # Serialize the bounded provider start with admission, consent withdrawal,
    # call termination, and identity eviction. The earlier durable claim still
    # prevents replay if the provider response or this process is lost.
    effect_deadline = System.monotonic_time(:millisecond) + 30_000

    result =
      transaction(
        fn ->
          snapshot = Repo.get(Artifact, request.artifact_id) || Repo.rollback(:not_found)
          identity_deadline = System.monotonic_time(:millisecond) + 15_000
          protection = protection!(snapshot)

          subject = %{
            tenant_id: snapshot.tenant_id,
            user_id: snapshot.requested_by_user_id,
            device_id: snapshot.requested_by_device_id,
            session_id: snapshot.requested_by_session_id
          }

          retained_authority = DerivedAuthority.lock(snapshot, subject, identity_deadline)

          retained_subjects =
            case retained_authority do
              {:ok, {_, subjects}} -> subjects
              _ -> []
            end

          access = AuthorizationPolicy.lock_access(subject, snapshot.conversation_id, :share)

          call =
            Repo.one!(
              from(c in AudioCall,
                where: c.id == ^request.call_id and c.tenant_id == ^request.tenant_id,
                lock: "FOR UPDATE"
              )
            )

          artifact = lock_id!(request.artifact_id)
          participants = admitted(call)

          current_access =
            match?({:ok, _}, retained_authority) and match?({:ok, _}, access) and
              current_participant_access?(participants) and
              DerivedAuthority.current?([subject | retained_subjects], snapshot.conversation_id)

          effect_budget_available = effect_budget_available?(effect_deadline, 25_000)

          if effect_budget_available and artifact.status == :starting and
               is_nil(artifact.erasure_requested_at) and
               not protection.capture_blocked and
               call.status == :active and
               DateTime.compare(call.expires_at, now()) == :gt and
               DateTime.compare(artifact.expires_at, now()) == :gt and
               policy_enabled?(%{tenant_id: artifact.tenant_id}) and
               all_consented?(artifact, participants) and current_access do
            ArtifactProviderPort.start(provider_request(artifact))
          else
            if artifact.status in [:starting, :stopping] and is_nil(artifact.provider_job_id) do
              update!(
                Artifact.changeset(artifact, %{
                  status: :failed,
                  failure_code:
                    if(effect_budget_available,
                      do: "capture_authorization_changed",
                      else: "capture_start_budget_exhausted"
                    ),
                  ended_at: now()
                })
              )
            end

            {:error, :artifact_start_authorization_changed}
          end
        end,
        timeout: 30_000
      )

    case result do
      {:ok, provider_result} -> provider_result
      {:error, _} = error -> error
    end
  end

  def prepare_governance_erasure(tenant_id, target_type, target_id)
      when target_type in [:user, :conversation, :message] do
    if Repo.in_transaction?() do
      if not valid_uuid?(tenant_id) or not valid_uuid?(target_id),
        do: Repo.rollback(:invalid_governance_target)

      # The protection port holds Governance's tenant lock throughout the owning
      # transaction. Check every participant before mutating any affected artifact.
      snapshots = Repo.all(erasure_query(tenant_id, target_type, target_id))
      if snapshots != [], do: protection!(tenant_id, hd(snapshots).conversation_id, [])
      if Enum.any?(snapshots, &protection!(&1).held), do: Repo.rollback(:artifact_legal_hold)
      call_ids = snapshots |> Enum.map(& &1.call_id) |> Enum.uniq() |> Enum.sort()

      Repo.all(
        from(c in AudioCall,
          where: c.tenant_id == ^tenant_id and c.id in ^call_ids,
          order_by: [asc: c.id],
          lock: "FOR UPDATE"
        )
      )

      snapshots = Repo.all(erasure_query(tenant_id, target_type, target_id))
      if Enum.any?(snapshots, &protection!(&1).held), do: Repo.rollback(:artifact_legal_hold)

      Enum.each(snapshots, fn snapshot ->
        artifact = lock_id!(snapshot.id)

        if artifact.status != :deleted do
          artifact =
            update!(
              Artifact.changeset(artifact, %{
                erasure_requested_at: artifact.erasure_requested_at || now()
              })
            )

          artifact =
            if artifact.status in @capturing,
              do: stop!(artifact, "governance_erasure_requested"),
              else: update!(Artifact.changeset(artifact, %{status: :deleting}))

          enqueue!(artifact)
        end
      end)

      {:ok, %ArtifactErasurePlan{pending_artifact_count: length(snapshots)}}
    else
      {:error, :transaction_required}
    end
  end

  def prepare_governance_erasure(_, _, _), do: {:error, :invalid_governance_target}

  def governance_erasure_pending?(tenant_id, target_type, target_id)
      when target_type in [:user, :conversation, :message] do
    if valid_uuid?(tenant_id) and valid_uuid?(target_id),
      do: {:ok, Repo.exists?(erasure_query(tenant_id, target_type, target_id))},
      else: {:error, :invalid_governance_target}
  end

  def governance_erasure_pending?(_, _, _), do: {:error, :invalid_governance_target}

  defp erasure_query(tenant_id, target_type, target_id) do
    query =
      from(a in Artifact,
        where: a.tenant_id == ^tenant_id and a.status != :deleted,
        order_by: [
          asc:
            fragment("CASE ? WHEN 'recording' THEN 0 WHEN 'transcript' THEN 1 ELSE 2 END", a.kind),
          asc: a.id
        ]
      )

    case target_type do
      :conversation ->
        where(query, [a], a.conversation_id == ^target_id)

      :user ->
        matching_consents =
          from(c in Consent,
            where: c.tenant_id == ^tenant_id and c.user_id == ^target_id,
            select: c.artifact_id
          )

        where(
          query,
          [a],
          a.requested_by_user_id == ^target_id or a.id in subquery(matching_consents)
        )

      :message ->
        where(query, [a], false)
    end
  end

  defp current_participant_access?(participants) do
    participants != [] and
      Enum.all?(participants, fn participant ->
        match?(
          {:ok, _},
          Accounts.access_grant(%{
            tenant_id: participant.tenant_id,
            user_id: participant.user_id,
            device_id: participant.device_id,
            session_id: participant.session_id
          })
        )
      end)
  end

  defp authorized_call(conversation_id, call_id, subject) do
    if not valid_uuid?(conversation_id) or not valid_uuid?(call_id) or
         not valid_uuid?(value(subject, :tenant_id)) do
      {:error, :not_found}
    else
      authorized_valid_call(conversation_id, call_id, subject)
    end
  end

  defp authorized_valid_call(conversation_id, call_id, subject) do
    if guest?(subject) and value(subject, :guest_conversation_id) != conversation_id do
      {:error, :forbidden}
    else
      case Repo.get_by(AudioCall,
             tenant_id: value(subject, :tenant_id),
             conversation_id: conversation_id,
             id: call_id
           ) do
        %AudioCall{} = call ->
          with :ok <- AuthorizationPolicy.authorize(:read_call, subject, call), do: {:ok, call}

        _ ->
          {:error, :not_found}
      end
    end
  end

  defp locked_call!(conversation_id, call_id, subject) do
    if not valid_uuid?(conversation_id) or not valid_uuid?(call_id) or
         not valid_uuid?(value(subject, :tenant_id)),
       do: Repo.rollback(:not_found)

    if guest?(subject) and value(subject, :guest_conversation_id) != conversation_id,
      do: Repo.rollback(:forbidden)

    access =
      case AuthorizationPolicy.lock_access(subject, conversation_id, :update) do
        {:ok, access} -> access
        {:error, reason} -> Repo.rollback(reason)
      end

    call =
      Repo.one(
        from(c in AudioCall,
          where:
            c.tenant_id == ^access.tenant_id and c.conversation_id == ^conversation_id and
              c.id == ^call_id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:not_found)

    call
  end

  defp locked_artifact!(call, id) do
    if not valid_uuid?(id), do: Repo.rollback(:not_found)

    Repo.one(
      from(a in Artifact,
        where: a.id == ^id and a.tenant_id == ^call.tenant_id and a.call_id == ^call.id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  defp lock_id!(id),
    do:
      Repo.one(from(a in Artifact, where: a.id == ^id, lock: "FOR UPDATE")) ||
        Repo.rollback(:not_found)

  defp manage!(call, subject) do
    if guest?(subject), do: Repo.rollback(:forbidden)

    case AuthorizationPolicy.authorize(
           if(call.media_kind == :video, do: :end_video_call, else: :end_audio_call),
           subject,
           call
         ) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp active!(call) do
    if call.status != :active or DateTime.compare(call.expires_at, now()) != :gt,
      do: Repo.rollback(:audio_call_expired)
  end

  defp admitted(call),
    do:
      Repo.all(
        from(p in AudioCallParticipant,
          where:
            p.tenant_id == ^call.tenant_id and p.audio_call_id == ^call.id and
              p.status == :admitted
        )
      )

  defp snapshot_consents!(artifact, participants) do
    Enum.each(participants, fn p ->
      if is_nil(Repo.get_by(Consent, artifact_id: artifact.id, participant_id: p.id)),
        do: insert!(Consent.changeset(%Consent{}, consent_attrs(artifact, p)))
    end)
  end

  defp consent_attrs(artifact, p),
    do: %{
      tenant_id: artifact.tenant_id,
      artifact_id: artifact.id,
      participant_id: p.id,
      user_id: p.user_id,
      session_id: p.session_id,
      accepted: false
    }

  defp all_consented?(artifact, participants) do
    accepted =
      Repo.all(
        from(c in Consent,
          where:
            c.artifact_id == ^artifact.id and c.accepted == true and
              (not (^artifact.summary_requested) or
                 (c.summary_accepted and c.summary_policy_version == "meeting-summary-v1")),
          select: c.participant_id
        )
      )
      |> MapSet.new()

    participants != [] and Enum.all?(participants, &MapSet.member?(accepted, &1.id))
  end

  defp ensure_all_consented!(artifact, participants) do
    snapshot_consents!(artifact, participants)
    if not all_consented?(artifact, participants), do: Repo.rollback(:recording_consent_required)
  end

  defp stop!(artifact, reason) do
    updated = update!(Artifact.changeset(artifact, %{status: :stopping, failure_code: reason}))
    enqueue!(updated)
    updated
  end

  defp protection!(artifact),
    do:
      protection!(
        artifact.tenant_id,
        artifact.conversation_id,
        Enum.uniq([
          artifact.requested_by_user_id
          | Repo.all(from(c in Consent, where: c.artifact_id == ^artifact.id, select: c.user_id))
        ])
      )

  defp protection!(tenant_id, conversation_id, user_ids) do
    case ArtifactProtectionPort.protection(tenant_id, conversation_id, user_ids) do
      {:ok, protection} -> protection
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp provider_request(a),
    do: %ArtifactProviderRequest{
      tenant_id: a.tenant_id,
      conversation_id: a.conversation_id,
      call_id: a.call_id,
      artifact_id: a.id,
      provider_room: a.provider_room,
      provider_job_id: a.provider_job_id,
      object_key: a.object_key,
      content_type: a.content_type,
      operation_key: a.idempotency_key
    }

  defp storage_object(a),
    do: %ArtifactStorageObject{
      tenant_id: a.tenant_id,
      object_key: a.object_key,
      content_type: a.content_type,
      object_version_id: a.object_version_id,
      checksum_sha256: a.checksum_sha256,
      verified_checksum_sha256: a.checksum_sha256,
      object_etag: a.object_etag,
      byte_size: a.byte_size
    }

  defp view(a, subject, call) do
    consents = Repo.all(from(c in Consent, where: c.artifact_id == ^a.id))
    participants = if call && call.status == :active, do: admitted(call), else: []

    current =
      if participants == [],
        do: consents,
        else:
          Enum.filter(consents, fn c -> Enum.any?(participants, &(&1.id == c.participant_id)) end)

    own = Enum.find(consents, &(&1.session_id == value(subject, :session_id)))

    can_manage =
      if not is_nil(call) and not guest?(subject),
        do:
          AuthorizationPolicy.authorize(
            if(call.media_kind == :video, do: :end_video_call, else: :end_audio_call),
            subject,
            call
          ) == :ok,
        else: false

    %ArtifactView{
      id: a.id,
      conversation_id: a.conversation_id,
      call_id: a.call_id,
      meeting_id: a.meeting_id,
      source_artifact_id: a.source_artifact_id,
      transcript_language: a.transcript_language,
      summary_requested: a.summary_requested,
      summary_policy_version: if(a.summary_requested, do: Summaries.policy_version(), else: nil),
      summary_consent_required_count:
        if(a.summary_requested, do: max(length(current), length(participants)), else: 0),
      summary_consent_accepted_count: Enum.count(current, & &1.summary_accepted),
      my_summary_consent: if(own, do: own.summary_accepted, else: nil),
      can_withdraw_summary_consent:
        a.kind == :recording and a.summary_requested and
          Enum.any?(consents, &(&1.user_id == value(subject, :user_id) and &1.summary_accepted)),
      summary_request_available:
        a.kind == :transcript and a.status == :available and a.summary_requested and
          not is_nil(call) and call.status == :ended and source_summary_consented?(a) and
          not Repo.exists?(
            from(child in Artifact,
              where:
                child.tenant_id == ^a.tenant_id and
                  child.source_artifact_id == ^a.id and child.kind == :summary
            )
          ),
      recognition_mode: if(a.kind == :transcript, do: "post_recording", else: nil),
      recognition_model_sha256: a.recognition_model_sha256,
      kind: a.kind,
      status: a.status,
      created_at: a.inserted_at,
      started_at: a.started_at,
      ended_at: a.ended_at,
      expires_at: a.expires_at,
      failure_code: a.failure_code,
      consent_required_count: max(length(current), length(participants)),
      consent_accepted_count: Enum.count(current, & &1.accepted),
      my_consent:
        if(own,
          do: own.accepted,
          else:
            if(Enum.any?(participants, &(&1.session_id == value(subject, :session_id))),
              do: false,
              else: nil
            )
        ),
      can_manage: can_manage,
      byte_size: a.byte_size,
      content_type: a.content_type
    }
  end

  defp source_summary_consented?(transcript) do
    source =
      Repo.get_by(Artifact,
        id: transcript.source_artifact_id,
        tenant_id: transcript.tenant_id,
        call_id: transcript.call_id,
        kind: :recording
      )

    if source && source.summary_requested && source.status == :available &&
         is_nil(source.erasure_requested_at) && DateTime.compare(source.expires_at, now()) == :gt do
      decisions =
        Repo.all(
          from(c in Consent,
            where: c.tenant_id == ^source.tenant_id and c.artifact_id == ^source.id
          )
        )

      decisions != [] and
        Enum.all?(
          decisions,
          &(&1.accepted and &1.summary_accepted and
              &1.summary_policy_version == "meeting-summary-v1")
        )
    else
      false
    end
  end

  defp root_artifact_for_summary(%Artifact{kind: :recording} = a), do: a

  defp root_artifact_for_summary(a) do
    source = Repo.get!(Artifact, a.source_artifact_id)
    root_artifact_for_summary(source)
  end

  defp valid_callback(event) do
    if is_map(event) and is_binary(Map.get(event, :event_id)) and
         byte_size(event.event_id) in 1..200 and
         is_binary(Map.get(event, :provider_job_id)) and is_binary(Map.get(event, :provider_room)) and
         (is_binary(Map.get(event, :object_key)) or
            (is_nil(Map.get(event, :object_key)) and Map.get(event, :state) != :available)) and
         Map.get(event, :state) in [:recording, :processing, :available, :failed] and
         (Map.get(event, :state) != :available or
            (is_integer(Map.get(event, :byte_size)) and event.byte_size in 1..10_737_418_240)),
       do: :ok,
       else: {:error, :invalid_provider_webhook}
  end

  defp maybe_put_size(attrs, size) when is_integer(size) and size in 1..10_737_418_240,
    do: Map.put(attrs, :byte_size, size)

  defp maybe_put_size(attrs, _), do: attrs
  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(""), do: {:ok, nil}

  defp optional_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :invalid_search_scope}
    end
  end

  defp escape_like(text),
    do:
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

  defp policy_enabled?(subject) do
    policy = Application.get_env(:comms_core, :meeting_artifact_policy, [])

    Keyword.get(policy, :privacy_approved, false) and
      Keyword.get(policy, :provider_qualified, false) and
      value(subject, :tenant_id) in Keyword.get(policy, :enabled_tenant_ids, []) and
      not guest?(subject) and
      Application.get_env(:comms_core, :direct_audio_p2p_enabled, false) != true
  end

  defp ensure_livekit_capture!() do
    if Application.get_env(:comms_core, :direct_audio_p2p_enabled, false) == true,
      do: Repo.rollback(:recording_requires_livekit)
  end

  defp guest?(subject),
    do:
      value(subject, :account_type) in [:guest, "guest"] or
        is_binary(value(subject, :guest_conversation_id))

  defp valid_uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))

  defp meeting_id(call) do
    case CommsCore.AudioCalls.MeetingCallPolicy.meeting_for_call(call.tenant_id, call.id) do
      %{meeting_id: id} -> id
      _ -> nil
    end
  end

  defp enqueue!(artifact) do
    worker =
      RuntimePorts.job_worker_name!(
        if(artifact.kind == :summary, do: :call_summary, else: :call_artifact)
      )

    changeset =
      Oban.Job.new(%{artifact_id: artifact.id},
        worker: worker,
        queue: :media,
        priority: if(artifact.status == :stopping, do: 0, else: 1),
        unique: [
          period: 30,
          fields: [:worker, :args],
          keys: [:artifact_id],
          states: [:available, :scheduled, :retryable]
        ]
      )

    case Oban.insert(changeset) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp audit!(artifact, subject, action) do
    case Audit.record(%{
           tenant_id: artifact.tenant_id,
           actor_user_id: value(subject, :user_id),
           action: action,
           resource_type: "call_artifact",
           resource_id: artifact.id,
           metadata: %{
             call_id: artifact.call_id,
             conversation_id: artifact.conversation_id,
             kind: artifact.kind
           },
           request_id: value(subject, :request_id)
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp system_audit!(artifact, action),
    do: audit!(artifact, %{user_id: artifact.requested_by_user_id}, action)

  defp insert!(changeset) do
    case Repo.insert(changeset) do
      {:ok, row} -> row
      {:error, changeset} -> Repo.rollback(validation_error(changeset))
    end
  end

  defp update!(changeset) do
    case Repo.update(changeset) do
      {:ok, row} -> row
      {:error, changeset} -> Repo.rollback(validation_error(changeset))
    end
  end

  defp validation_error(changeset) do
    {:ok, error} = CommsCore.ValidationError.from(changeset)
    error
  end

  defp effect_budget_available?(deadline, required_ms),
    do: deadline - System.monotonic_time(:millisecond) >= required_ms

  defp transaction(fun, options \\ []), do: Repo.transaction(fun, options)
  defp integer(v, _) when is_integer(v), do: v
  defp integer(_, default), do: default
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
