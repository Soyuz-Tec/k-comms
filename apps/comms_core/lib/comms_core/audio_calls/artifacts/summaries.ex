defmodule CommsCore.AudioCalls.Artifacts.Summaries do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Accounts, Audit, Repo, RuntimePorts}

  alias CommsCore.AudioCalls.{
    AudioCall,
    AuthorizationPolicy,
    ArtifactProtectionPort,
    ArtifactSummarizationPort,
    ArtifactSummaryRequest,
    ArtifactSummaryView
  }

  alias CommsCore.AudioCalls.Artifacts.{Artifact, Consent, DerivedAuthority, Segment, Summary}
  @policy "meeting-summary-v1"
  @max_text_bytes 131_072

  def policy_version, do: @policy

  def enabled?(tenant_id) do
    policy = Application.get_env(:comms_core, :meeting_artifact_policy, [])

    Keyword.get(policy, :summary_privacy_approved, false) and
      tenant_id in Keyword.get(policy, :enabled_tenant_ids, []) and
      ArtifactSummarizationPort.configured?()
  end

  def request(conversation_id, call_id, attrs, subject) do
    transaction(fn ->
      transcript = snapshot!(value(attrs, :source_artifact_id), subject, conversation_id, call_id)
      if transcript.kind != :transcript, do: Repo.rollback(:artifact_not_available)
      {root, transcript} = lineage!(transcript)
      {call, _consents, _subjects} = authority!(root, subject, false)
      root = lock!(root.id)
      transcript = lock!(transcript.id)
      manage!(call, subject)
      if call.status == :active, do: Repo.rollback(:summary_post_call_only)
      if not enabled?(root.tenant_id), do: Repo.rollback(:summarization_unavailable)
      consented!(root)
      available!(root)
      available!(transcript)
      {digest, _text} = source!(transcript)
      key = value(attrs, :idempotency_key)

      if not is_binary(key) or byte_size(key) not in 8..120,
        do: Repo.rollback(:idempotency_key_required)

      case Repo.get_by(Artifact,
             tenant_id: root.tenant_id,
             call_id: call.id,
             idempotency_key: key
           ) do
        %Artifact{kind: :summary, source_artifact_id: source_id} = existing
        when source_id == transcript.id ->
          CommsCore.AudioCalls.Artifacts.summary_metadata(existing, subject, call)

        %Artifact{} ->
          Repo.rollback(:idempotency_conflict)

        nil ->
          case Repo.get_by(Artifact,
                 tenant_id: root.tenant_id,
                 source_artifact_id: transcript.id,
                 kind: :summary
               ) do
            %Artifact{} = existing ->
              CommsCore.AudioCalls.Artifacts.summary_metadata(existing, subject, call)

            nil ->
              id = Ecto.UUID.generate()

              artifact =
                %Artifact{id: id}
                |> Artifact.changeset(%{
                  tenant_id: root.tenant_id,
                  conversation_id: root.conversation_id,
                  call_id: call.id,
                  meeting_id: root.meeting_id,
                  source_artifact_id: transcript.id,
                  requested_by_user_id: value(subject, :user_id),
                  requested_by_device_id: value(subject, :device_id),
                  requested_by_session_id: value(subject, :session_id),
                  kind: :summary,
                  status: :processing,
                  provider_room: root.provider_room,
                  object_key: "#{root.tenant_id}/meeting-artifacts/#{call.id}/#{id}.json",
                  content_type: "application/json",
                  expires_at: earlier(root.expires_at, transcript.expires_at),
                  idempotency_key: key,
                  summary_requested: true,
                  summary_source_sha256: digest
                })
                |> Repo.insert!()

              Enum.each(consents(root), fn c ->
                Repo.insert!(
                  Consent.changeset(%Consent{}, %{
                    tenant_id: c.tenant_id,
                    artifact_id: id,
                    participant_id: c.participant_id,
                    user_id: c.user_id,
                    session_id: c.session_id,
                    accepted: true,
                    decided_at: c.decided_at,
                    summary_accepted: true,
                    summary_policy_version: @policy,
                    summary_decided_at: c.summary_decided_at
                  })
                )
              end)

              enqueue!(artifact)
              audit!(artifact, subject, "call.summary_requested")
              CommsCore.AudioCalls.Artifacts.summary_metadata(artifact, subject, call)
          end
      end
    end)
  end

  def consent(conversation_id, call_id, id, attrs, subject) do
    transaction(fn ->
      accepted = value(attrs, :accepted)

      if not is_boolean(accepted) or value(attrs, :policy_version) != @policy,
        do: Repo.rollback(:invalid_summary_consent)

      root = snapshot!(id, subject, conversation_id, call_id)

      if root.kind != :recording or not root.summary_requested,
        do: Repo.rollback(:summary_not_disclosed)

      # Withdrawal remains available even if the original device/session left.
      # It never grants another session authority to accept the old admission.
      {call, _all, _subjects} = authority!(root, subject, not accepted)
      root = lock!(root.id)
      own = consents(root) |> Enum.filter(&(&1.user_id == value(subject, :user_id)))
      if own == [], do: Repo.rollback(:forbidden)

      if accepted do
        if call.status != :active or root.status != :pending_consent or
             DateTime.compare(call.expires_at, now()) != :gt,
           do: Repo.rollback(:artifact_not_capturing)

        own = Enum.filter(own, &(&1.session_id == value(subject, :session_id)))
        if own == [], do: Repo.rollback(:forbidden)
        Enum.each(own, &update_consent!(&1, true))
      else
        Enum.each(own, &update_consent!(&1, false))

        if root.status in [:starting, :recording],
          do:
            enqueue!(
              root
              |> Artifact.changeset(%{
                status: :stopping,
                failure_code: "summary_consent_withdrawn"
              })
              |> Repo.update!()
            )

        invalidate!(root)
      end

      audit!(
        root,
        subject,
        if(accepted, do: "call.summary_consent_accepted", else: "call.summary_consent_withdrawn")
      )

      CommsCore.AudioCalls.Artifacts.summary_metadata(Repo.get!(Artifact, root.id), subject, call)
    end)
  end

  def get(conversation_id, call_id, id, subject) do
    transaction(fn ->
      if value(subject, :account_type) == :guest or value(subject, :account_type) == "guest" or
           is_binary(value(subject, :guest_conversation_id)),
         do: Repo.rollback(:forbidden)

      artifact = snapshot!(id, subject, conversation_id, call_id)
      if artifact.kind != :summary, do: Repo.rollback(:artifact_not_available)
      {root, transcript} = lineage!(artifact)
      {call, _, _} = authority!(root, subject, false)
      root = lock!(root.id)
      transcript = lock!(transcript.id)
      artifact = lock!(artifact.id)
      consented!(root)
      Enum.each([root, transcript, artifact], &available!/1)

      summary =
        Repo.get_by(Summary, artifact_id: artifact.id, tenant_id: artifact.tenant_id) ||
          Repo.rollback(:artifact_not_available)

      {digest, source_text} = source!(transcript)

      if digest != summary.source_sha256 or digest != artifact.summary_source_sha256 or
           summary.source_artifact_id != transcript.id,
         do: Repo.rollback(:summary_source_changed)

      quotes = String.split(summary.text, "\n\n")
      source_lines = source_text |> String.split("\n", trim: true) |> MapSet.new()

      if hash(summary.text) != summary.summary_sha256 or summary.policy_version != @policy or
           summary.provider_model != "extractive-quotes-v1" or length(quotes) not in 1..6 or
           not Enum.all?(quotes, &MapSet.member?(source_lines, &1)),
         do: Repo.rollback(:summary_source_changed)

      audit!(artifact, subject, "call.summary_read")

      %{
        artifact: CommsCore.AudioCalls.Artifacts.summary_metadata(artifact, subject, call),
        summary: %ArtifactSummaryView{
          source_artifact_id: transcript.id,
          source_sha256: digest,
          summary_sha256: summary.summary_sha256,
          text: summary.text,
          policy_version: summary.policy_version
        }
      }
    end)
  end

  def process(id) do
    # Commit an immutable one-use intent BEFORE any provider request. The token
    # exists only in this process; reconciliation never reconstructs/replays it.
    with {:ok, {:execute, token}} <- claim(id) do
      result = execute(id, token)
      if match?({:error, _}, result), do: fail_claim(id, token)
      result
    else
      {:ok, state} -> {:ok, state}
      error -> error
    end
  end

  defp claim(id) do
    transaction(
      fn ->
        artifact = Repo.get(Artifact, id) || Repo.rollback(:not_found)
        {root, transcript} = lineage!(artifact)
        subject = requester(artifact)
        {call, _, subjects} = authority!(root, subject, false)
        root = lock!(root.id)
        transcript = lock!(transcript.id)
        artifact = lock!(artifact.id)

        cond do
          artifact.kind != :summary or artifact.status != :processing ->
            :idle

          not is_nil(artifact.summary_provider_claimed_at) ->
            # A read/reconcile during legitimate I/O must leave its consumed claim
            # alone. The effect transaction is bounded to 45s; 90s permits owner
            # lock waits before marking a lost response terminal and non-replayable.
            if DateTime.diff(now(), artifact.summary_provider_claimed_at, :second) >= 90 do
              artifact
              |> Artifact.changeset(%{
                status: :failed,
                failure_code: "summary_outcome_unknown",
                ended_at: now()
              })
              |> Repo.update!()

              :summary_failed
            else
              :claimed
            end

          true ->
            validate_effect!(root, transcript, artifact, call, [subject | subjects])
            token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

            artifact
            |> Artifact.changeset(%{
              summary_provider_claimed_at: now(),
              summary_claim_fingerprint: hash(token),
              summary_effect_started_at: now()
            })
            |> Repo.update!()

            {:execute, token}
        end
      end,
      timeout: 15_000
    )
  end

  defp execute(id, token) do
    deadline = System.monotonic_time(:millisecond) + 45_000

    transaction(
      fn ->
        artifact = Repo.get(Artifact, id) || Repo.rollback(:not_found)
        {root, transcript} = lineage!(artifact)
        subject = requester(artifact)
        {call, _, subjects} = authority!(root, subject, false)
        root = lock!(root.id)
        transcript = lock!(transcript.id)
        artifact = lock!(artifact.id)

        if artifact.status != :processing or artifact.summary_claim_fingerprint != hash(token) or
             is_nil(artifact.summary_provider_claimed_at),
           do: Repo.rollback(:summary_claim_consumed)

        {digest, text} = validate_effect!(root, transcript, artifact, call, [subject | subjects])

        if System.monotonic_time(:millisecond) + 31_000 >= deadline,
          do: Repo.rollback(:artifact_processing_budget_exhausted)

        request = %ArtifactSummaryRequest{
          artifact_id: artifact.id,
          source_artifact_id: transcript.id,
          source_sha256: digest,
          text: text,
          deadline: deadline - 1_000
        }

        case ArtifactSummarizationPort.summarize(request) do
          {:ok, receipt} ->
            if System.monotonic_time(:millisecond) >= deadline,
              do: Repo.rollback(:artifact_processing_budget_exhausted)

            validate_effect!(root, transcript, artifact, call, [subject | subjects])

            Repo.insert!(
              Summary.changeset(%Summary{}, %{
                tenant_id: artifact.tenant_id,
                artifact_id: artifact.id,
                source_artifact_id: transcript.id,
                source_sha256: digest,
                summary_sha256: hash(receipt.text),
                policy_version: @policy,
                provider_id: receipt.provider_id,
                provider_model: receipt.model,
                text: receipt.text
              })
            )

            artifact
            |> Artifact.changeset(%{status: :available, ended_at: now(), failure_code: nil})
            |> Repo.update!()

            audit!(artifact, subject, "call.summary_available")
            :summarized

          {:error, _} ->
            artifact
            |> Artifact.changeset(%{
              status: :failed,
              ended_at: now(),
              failure_code: "summary_outcome_unknown"
            })
            |> Repo.update!()

            audit!(artifact, subject, "call.summary_failed")
            :summary_failed
        end
      end,
      timeout: 45_000
    )
  end

  defp validate_effect!(root, transcript, artifact, call, subjects) do
    consented!(root)
    Enum.each([root, transcript], &available!/1)

    if call.status == :active or not enabled?(root.tenant_id) or
         not is_nil(artifact.erasure_requested_at) or
         DateTime.compare(artifact.expires_at, now()) != :gt or
         not DerivedAuthority.current?(subjects, root.conversation_id),
       do: Repo.rollback(:forbidden)

    {digest, text} = source!(transcript)
    if digest != artifact.summary_source_sha256, do: Repo.rollback(:summary_source_changed)
    {digest, text}
  end

  defp fail_claim(id, token) do
    # Content-free terminal CAS cannot resurrect an erased or withdrawn artifact.
    Repo.update_all(
      from(a in Artifact,
        where:
          a.id == ^id and a.status == :processing and
            a.summary_claim_fingerprint == ^hash(token)
      ),
      set: [
        status: :failed,
        failure_code: "summary_outcome_unknown",
        ended_at: now(),
        updated_at: now()
      ]
    )
  end

  defp requester(a),
    do: %{
      tenant_id: a.tenant_id,
      user_id: a.requested_by_user_id,
      device_id: a.requested_by_device_id,
      session_id: a.requested_by_session_id
    }

  def rollback_hazard_count() do
    Repo.aggregate(Summary, :count, :id) +
      Repo.aggregate(
        from(a in Artifact,
          where:
            a.kind == :summary or a.summary_requested or not is_nil(a.summary_source_sha256) or
              not is_nil(a.summary_provider_claimed_at) or not is_nil(a.summary_claim_fingerprint) or
              not is_nil(a.summary_effect_started_at) or not is_nil(a.recognition_provider_id) or
              not is_nil(a.recognition_model_sha256) or not is_nil(a.recognition_source_sha256)
        ),
        :count,
        :id
      ) +
      Repo.aggregate(
        from(c in Consent,
          where:
            c.summary_accepted or not is_nil(c.summary_policy_version) or
              not is_nil(c.summary_decided_at)
        ),
        :count,
        :id
      )
  end

  defp authority!(root, subject, withdrawal?) do
    deadline = System.monotonic_time(:millisecond) + 15_000

    # Discover original consent provenance only after its Governance barrier;
    # the second projection evaluates that fresh user set under the same lock.
    case ArtifactProtectionPort.protection(root.tenant_id, root.conversation_id, []) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    cs = consents(root)

    protection =
      case ArtifactProtectionPort.protection(
             root.tenant_id,
             root.conversation_id,
             [value(subject, :user_id) | Enum.map(cs, & &1.user_id)] |> Enum.uniq()
           ) do
        {:ok, protection} -> protection
        {:error, reason} -> Repo.rollback(reason)
      end

    if protection.capture_blocked and not withdrawal?,
      do: Repo.rollback(:artifact_erasure_pending)

    requester =
      Map.new([:tenant_id, :user_id, :device_id, :session_id], &{&1, value(subject, &1)})

    {cs, subjects} =
      if withdrawal? do
        case Accounts.lock_content_write_grant(requester, deadline) do
          {:ok, _} -> {cs, []}
          _ -> Repo.rollback(:forbidden)
        end
      else
        DerivedAuthority.lock!(root, requester, deadline)
      end

    case AuthorizationPolicy.lock_access(subject, root.conversation_id, :share) do
      {:ok, _} -> :ok
      _ -> Repo.rollback(:forbidden)
    end

    call =
      Repo.one!(
        from(c in AudioCall,
          where: c.id == ^root.call_id and c.tenant_id == ^root.tenant_id,
          lock: "FOR UPDATE"
        )
      )

    if not withdrawal? and
         not DerivedAuthority.current?([requester | subjects], root.conversation_id),
       do: Repo.rollback(:forbidden)

    {call, cs, subjects}
  end

  defp lineage!(%Artifact{kind: :recording} = root), do: {root, nil}

  defp lineage!(%Artifact{kind: :transcript} = transcript) do
    root =
      Repo.get(Artifact, transcript.source_artifact_id) || Repo.rollback(:artifact_not_available)

    if root.kind != :recording or not same_call?(root, transcript),
      do: Repo.rollback(:artifact_not_available)

    {root, transcript}
  end

  defp lineage!(%Artifact{kind: :summary} = artifact) do
    transcript =
      Repo.get(Artifact, artifact.source_artifact_id) || Repo.rollback(:artifact_not_available)

    if transcript.kind != :transcript or not same_call?(transcript, artifact),
      do: Repo.rollback(:artifact_not_available)

    lineage!(transcript)
  end

  defp lineage!(_), do: Repo.rollback(:artifact_not_available)

  defp same_call?(a, b),
    do:
      a.tenant_id == b.tenant_id and a.call_id == b.call_id and
        a.conversation_id == b.conversation_id

  defp consented!(root) do
    cs = consents(root)

    if not root.summary_requested or cs == [] or
         Enum.any?(
           cs,
           &(!&1.accepted or !&1.summary_accepted or &1.summary_policy_version != @policy)
         ),
       do: Repo.rollback(:summary_consent_required)
  end

  defp source!(transcript) do
    rows =
      Repo.all(
        from(s in Segment,
          where: s.tenant_id == ^transcript.tenant_id and s.artifact_id == ^transcript.id,
          order_by: s.sequence,
          limit: 10_001
        )
      )

    canonical = Enum.map(rows, &[&1.sequence, &1.start_ms, &1.end_ms, &1.text]) |> Jason.encode!()
    text = Enum.map_join(rows, "\n", & &1.text)

    if rows == [] or length(rows) > 10_000 or byte_size(text) > @max_text_bytes,
      do: Repo.rollback(:summary_source_too_large)

    {hash(canonical), text}
  end

  defp available!(a) do
    if a.status != :available or not is_nil(a.erasure_requested_at) or
         DateTime.compare(a.expires_at, now()) != :gt,
       do: Repo.rollback(:artifact_not_available)
  end

  defp snapshot!(id, subject, conversation_id, call_id) do
    if not Enum.all?([id, conversation_id, call_id], &match?({:ok, _}, Ecto.UUID.cast(&1))),
      do: Repo.rollback(:not_found)

    Repo.get_by(Artifact,
      id: id,
      tenant_id: value(subject, :tenant_id),
      conversation_id: conversation_id,
      call_id: call_id
    ) || Repo.rollback(:not_found)
  end

  defp consents(root),
    do:
      Repo.all(
        from(c in Consent, where: c.tenant_id == ^root.tenant_id and c.artifact_id == ^root.id)
      )

  defp update_consent!(c, accepted),
    do:
      c
      |> Consent.changeset(%{
        summary_accepted: accepted,
        summary_policy_version: @policy,
        summary_decided_at: now()
      })
      |> Repo.update!()

  @doc false
  def invalidate(root), do: invalidate!(root)

  defp invalidate!(root) do
    transcripts =
      Repo.all(
        from(a in Artifact,
          where: a.tenant_id == ^root.tenant_id and a.source_artifact_id == ^root.id,
          order_by: a.id,
          lock: "FOR UPDATE",
          select: a.id
        )
      )

    children =
      Repo.all(
        from(a in Artifact,
          where:
            a.tenant_id == ^root.tenant_id and a.kind == :summary and
              a.source_artifact_id in ^transcripts,
          order_by: a.id,
          lock: "FOR UPDATE"
        )
      )

    Enum.each(children, fn a ->
      if a.status != :deleted,
        do:
          enqueue!(
            a
            |> Artifact.changeset(%{
              erasure_requested_at: a.erasure_requested_at || now(),
              status: :deleting
            })
            |> Repo.update!()
          )
    end)
  end

  defp lock!(id), do: Repo.one!(from(a in Artifact, where: a.id == ^id, lock: "FOR UPDATE"))

  defp manage!(call, subject) do
    case AuthorizationPolicy.authorize(
           if(call.media_kind == :video, do: :end_video_call, else: :end_audio_call),
           subject,
           call
         ) do
      :ok -> :ok
      _ -> Repo.rollback(:forbidden)
    end
  end

  defp enqueue!(a),
    do:
      %{"artifact_id" => a.id}
      |> Oban.Job.new(
        worker:
          RuntimePorts.job_worker_name!(
            if(a.kind == :summary, do: :call_summary, else: :call_artifact)
          ),
        queue: :media
      )
      |> Oban.insert!()

  defp audit!(a, subject, action) do
    case Audit.record(%{
           tenant_id: a.tenant_id,
           actor_user_id: value(subject, :user_id),
           action: action,
           resource_type: "call_artifact",
           resource_id: a.id,
           metadata: %{kind: a.kind, source_artifact_id: a.source_artifact_id}
         }) do
      {:ok, _} -> :ok
      _ -> Repo.rollback(:audit_failed)
    end
  end

  defp transaction(fun, options \\ []), do: Repo.transaction(fun, options)
  defp earlier(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)
  defp hash(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
