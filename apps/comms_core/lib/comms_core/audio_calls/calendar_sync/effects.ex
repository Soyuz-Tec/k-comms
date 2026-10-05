defmodule CommsCore.AudioCalls.CalendarSync.Effects do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Repo, RuntimePorts}
  alias CommsCore.AudioCalls.{Meeting, MeetingOccurrence}

  alias CommsCore.AudioCalls.CalendarSync.{
    Boxes,
    Budget,
    Commands,
    Connection,
    Connections,
    EventCommand,
    EventMapping,
    EventReceipt,
    Export,
    ExternalIdentityReceipt,
    Guards,
    OAuthRequest,
    ProviderAdapter,
    SecretContext,
    SyncCommand,
    TokenReceipt
  }

  @active [:queued, :leased, :uncertain, :retryable, :blocked]

  def perform(id, generation, caller) do
    if RuntimePorts.authorized_job_worker?(:calendar_sync, caller) do
      with {:ok, id} <- Ecto.UUID.cast(id),
           true <- is_integer(generation) and generation > 0,
           {:ok, claimed} <- claim(id, generation) do
        case claimed do
          nil ->
            {:ok, :ignored}

          command ->
            result =
              Budget.transaction(fn deadline ->
                try do
                  effect!(command, deadline)
                catch
                  {:calendar_retained_pending, reason} -> reason
                end
              end)

            # A committed pre-effect lease survives a crash/rollback. Never lose a possible create intent.
            if match?({:error, _}, result), do: uncertain_after_abort(command)
            result
        end
      else
        false -> {:error, :invalid_calendar_command}
        :error -> {:error, :invalid_calendar_command}
        error -> error
      end
    else
      {:error, :forbidden}
    end
  end

  def reconcile(limit, caller) when is_integer(limit) and limit in 1..100 do
    if RuntimePorts.authorized_job_worker?(:calendar_sync_reconciler, caller) do
      timestamp = Budget.now()

      Repo.transaction(fn ->
        expired =
          Repo.all(
            from(c in SyncCommand,
              where: c.status == :leased and c.lease_expires_at < ^timestamp,
              order_by: [asc: c.id],
              limit: ^limit,
              lock: "FOR UPDATE SKIP LOCKED"
            )
          )

        Enum.each(expired, fn command ->
          Repo.update!(
            Ecto.Changeset.change(command,
              status: :uncertain,
              available_at: timestamp,
              safe_reason: "effect_acknowledgement_unknown"
            )
          )
        end)

        queued =
          Repo.all(
            from(c in SyncCommand,
              where:
                c.status in [:queued, :retryable, :uncertain] and
                  c.available_at <= ^timestamp and c.attempt < 20,
              order_by: [asc: c.available_at, asc: c.id],
              limit: ^limit
            )
          )

        Enum.each(queued, &Commands.enqueue!/1)

        %{
          enqueued: length(queued),
          expired_leases: length(expired),
          has_more: length(queued) == limit
        }
      end)
    else
      {:error, :forbidden}
    end
  end

  def reconcile(_, _), do: {:error, :invalid_calendar_limit}

  defp claim(id, generation) do
    Repo.transaction(
      fn ->
        command = Repo.one(from(c in SyncCommand, where: c.id == ^id, lock: "FOR UPDATE"))
        timestamp = Budget.now()

        cond do
          is_nil(command) or command.consent_generation != generation or
              command.status in [:done, :failed, :blocked] ->
            nil

          command.status == :leased and
              DateTime.compare(command.lease_expires_at, timestamp) == :gt ->
            nil

          DateTime.compare(command.available_at, timestamp) == :gt ->
            nil

          command.attempt >= 20 ->
            Repo.update!(
              Ecto.Changeset.change(command, status: :failed, safe_reason: "attempts_exhausted")
            )

            nil

          true ->
            # Independent short claim has no parent/provider effect. Parent order starts afresh below.
            Repo.update!(
              Ecto.Changeset.change(command,
                status: :leased,
                attempt: command.attempt + 1,
                lease_id: Ecto.UUID.generate(),
                lease_expires_at: DateTime.add(timestamp, 45),
                safe_reason:
                  if(command.status in [:uncertain, :leased],
                    do: "effect_acknowledgement_unknown",
                    else: command.safe_reason
                  )
              )
            )
        end
      end,
      timeout: 5_000
    )
  end

  defp effect!(claimed, deadline) do
    initial = Repo.get!(Connection, claimed.connection_id)
    mapping_initial = if claimed.mapping_id, do: Repo.get!(EventMapping, claimed.mapping_id)
    export_initial = if mapping_initial, do: Repo.get!(Export, mapping_initial.export_id)

    purpose =
      if not is_nil(initial.fenced_at) or
           (not is_nil(mapping_initial) and not is_nil(mapping_initial.tombstoned_at)) or
           claimed.operation in [:delete, :verify_absence, :revoke, :destroy],
         do: :cleanup,
         else: :export

    authors = if export_initial, do: export_initial.author_user_ids, else: [initial.user_id]
    conversation = if export_initial, do: export_initial.conversation_id
    Guards.protection!(initial.tenant_id, conversation, authors, deadline, purpose)
    Guards.worker!(initial, deadline, purpose)
    policy = Guards.policy!(initial.tenant_id, deadline, purpose)
    connection = Repo.one(from(c in Connection, where: c.id == ^initial.id, lock: "FOR UPDATE"))

    if purpose == :export and
         (not policy.export_allowed? or connection.export_policy_version != policy.version or
            connection.status != :ready or not is_nil(connection.fenced_at)),
       do: Repo.rollback(:calendar_export_disabled)

    meeting =
      if mapping_initial do
        Repo.one(
          from(m in Meeting,
            where: m.id == ^mapping_initial.meeting_id and m.tenant_id == ^connection.tenant_id,
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:calendar_source_unavailable)
      end

    export =
      if export_initial,
        do: Repo.one(from(e in Export, where: e.id == ^export_initial.id, lock: "FOR UPDATE"))

    mapping =
      if mapping_initial,
        do:
          Repo.one(
            from(m in EventMapping, where: m.id == ^mapping_initial.id, lock: "FOR UPDATE")
          )

    command = Repo.one(from(c in SyncCommand, where: c.id == ^claimed.id, lock: "FOR UPDATE"))

    unless command.status == :leased and command.lease_id == claimed.lease_id,
      do: Repo.rollback(:calendar_claim_expired)

    if command.consent_generation != connection.consent_generation or
         command.credential_generation != connection.credential_generation do
      finish!(command)
      if mapping, do: Commands.insert!(connection, mapping, :reconcile)
      :obsolete
    else
      network_deadline = Budget.network_deadline(deadline)

      if is_nil(connection.credentials_box) and connection.status == :removed and
           connection.provider_grant_revocation in [:confirmed, :external_unconfirmed] do
        finish!(command)
        throw({:calendar_retained_pending, :local_credentials_already_destroyed})
      end

      {connection, credentials, identity} = credentials!(connection, command, network_deadline)
      Budget.check!(deadline)

      if mapping do
        if purpose == :export do
          unless is_nil(export.tombstoned_at) and is_nil(mapping.tombstoned_at) and
                   meeting.status == :scheduled and is_nil(meeting.erasure_requested_at) and
                   is_nil(meeting.erased_at) and
                   meeting.host_user_id == connection.user_id and meeting.author_lineage_complete,
                 do: Repo.rollback(:calendar_export_blocked)

          if meeting.version != mapping.desired_meeting_version do
            finish!(command)
            :obsolete
          else
            effect =
              event_command(
                connection,
                credentials,
                identity,
                mapping,
                meeting,
                command,
                purpose,
                network_deadline
              )

            receipt = provider_event(effect)

            apply_receipt!(
              connection,
              mapping,
              export,
              command,
              receipt,
              purpose,
              effect.operation
            )
          end
        else
          effect =
            event_command(
              connection,
              credentials,
              identity,
              mapping,
              meeting,
              command,
              purpose,
              network_deadline
            )

          receipt = provider_event(effect)
          apply_receipt!(connection, mapping, export, command, receipt, purpose, effect.operation)
        end
      else
        revoke!(connection, credentials, command, network_deadline)
      end
    end
  end

  defp credentials!(connection, command, deadline) do
    if is_nil(connection.credentials_box),
      do: Repo.rollback(:calendar_cleanup_credentials_missing)

    credentials =
      Boxes.decrypt!(
        connection.credentials_box,
        Connections.secret_context(connection, connection.id, :credential)
      )

    identity_fields =
      Boxes.decrypt!(
        connection.external_identity_box,
        Connections.secret_context(connection, connection.id, :external_identity)
      )

    identity = %ExternalIdentityReceipt{
      provider: connection.provider,
      external_subject: identity_fields["external_subject"],
      oidc_subject: identity_fields["oidc_subject"]
    }

    if is_nil(connection.access_expires_at) or
         DateTime.compare(connection.access_expires_at, DateTime.add(Budget.now(), 30)) != :gt do
      request = %OAuthRequest{
        provider: connection.provider,
        operation: :refresh,
        refresh_token: credentials["refresh_token"],
        deadline_ms: deadline
      }

      case ProviderAdapter.token(request) do
        {:ok, %TokenReceipt{provider: provider} = tokens} when provider == connection.provider ->
          generation = connection.credential_generation + 1
          refreshed = %{connection | credential_generation: generation}

          credentials = %{
            access_token: tokens.access_token,
            refresh_token: tokens.refresh_token || credentials["refresh_token"]
          }

          connection =
            Repo.update!(
              Ecto.Changeset.change(connection,
                credential_generation: generation,
                credentials_box:
                  Boxes.encrypt!(
                    credentials,
                    Connections.secret_context(refreshed, connection.id, :credential)
                  ),
                external_identity_box:
                  Boxes.encrypt!(
                    identity_fields,
                    Connections.secret_context(refreshed, connection.id, :external_identity)
                  ),
                access_expires_at: tokens.expires_at,
                version: connection.version + 1
              )
            )

          {connection, Map.new(credentials, fn {key, value} -> {Atom.to_string(key), value} end),
           identity}

        _ ->
          # Expired/revoked credentials remain a retained cleanup obligation, never success.
          Repo.update!(
            Ecto.Changeset.change(connection,
              status: :reauthorization_required,
              fenced_at: connection.fenced_at || Budget.now(),
              safe_reason: "cleanup_reauthorization_required",
              version: connection.version + 1
            )
          )

          block!(command, "cleanup_reauthorization_required")
          throw({:calendar_retained_pending, :reauthorization_required})
      end
    else
      {connection, credentials, identity}
    end
  end

  defp event_command(
         connection,
         credentials,
         identity,
         mapping,
         meeting,
         command,
         purpose,
         deadline
       ) do
    external =
      if mapping.external_identity_box,
        do:
          Boxes.decrypt!(mapping.external_identity_box, mapping_context(connection, mapping))[
            "external_id"
          ]

    etag =
      if mapping.etag_box,
        do: Boxes.decrypt!(mapping.etag_box, mapping_context(connection, mapping))["etag"]

    duplicate_ids =
      if mapping.duplicate_identities_box,
        do:
          Boxes.decrypt!(mapping.duplicate_identities_box, mapping_context(connection, mapping))[
            "ids"
          ],
        else: []

    operation =
      cond do
        purpose == :cleanup and command.safe_reason == "removal_accepted_verify" ->
          :reconcile

        purpose == :cleanup and duplicate_ids != [] ->
          :delete

        purpose == :cleanup and external ->
          :delete

        purpose == :cleanup ->
          :reconcile

        command.operation == :create and command.attempt == 1 and is_nil(command.safe_reason) ->
          :create

        command.operation == :update and etag ->
          :update

        true ->
          :reconcile
      end

    occurrence =
      if operation in [:create, :update],
        do:
          Repo.one(
            from(o in MeetingOccurrence,
              where:
                o.meeting_id == ^meeting.id and o.meeting_version == ^meeting.version and
                  o.sequence == ^mapping.occurrence_sequence and o.status == :scheduled
            )
          )

    if operation in [:create, :update] and is_nil(occurrence),
      do: Repo.rollback(:calendar_source_unavailable)

    origin = Application.get_env(:comms_core, :calendar_workspace_origin)

    %EventCommand{
      provider: connection.provider,
      operation: operation,
      marker_id: mapping.id,
      access_token: credentials["access_token"],
      identity: identity,
      deadline_ms: deadline,
      external_id: List.first(duplicate_ids) || external,
      etag: etag,
      title: if(occurrence, do: meeting.title),
      starts_at: if(occurrence, do: occurrence.starts_at),
      ends_at: if(occurrence, do: occurrence.ends_at),
      timezone: if(occurrence, do: meeting.timezone),
      authenticated_url:
        if(not is_nil(occurrence) and is_binary(origin),
          do: String.trim_trailing(origin, "/") <> "/app/meetings?meeting=" <> meeting.id
        )
    }
  end

  defp provider_event(effect) do
    case ProviderAdapter.event(effect) do
      {:ok, %EventReceipt{provider: provider} = receipt} when provider == effect.provider ->
        receipt

      _ ->
        %EventReceipt{provider: effect.provider, outcome: :uncertain}
    end
  end

  defp apply_receipt!(
         %Connection{} = connection,
         %EventMapping{} = mapping,
         %Export{} = export,
         %SyncCommand{} = command,
         %EventReceipt{} = receipt,
         purpose,
         operation
       ) do
    case receipt.outcome do
      outcome when outcome in [:applied, :present] ->
        mapping =
          Repo.update!(
            Ecto.Changeset.change(mapping,
              status: if(purpose == :cleanup, do: :removing, else: :present),
              external_identity_box:
                Boxes.encrypt!(
                  %{external_id: receipt.external_id},
                  mapping_context(connection, mapping)
                ),
              etag_box:
                Boxes.encrypt!(%{etag: receipt.etag}, mapping_context(connection, mapping)),
              applied_meeting_version:
                if(outcome == :applied,
                  do: mapping.desired_meeting_version,
                  else: mapping.applied_meeting_version
                ),
              duplicate_identities_box: nil
            )
          )

        finish!(command)

        if purpose == :cleanup do
          Commands.insert!(connection, mapping, :delete)
        else
          if outcome == :present, do: Commands.insert!(connection, mapping, :update)
        end

        refresh_export!(export)
        Repo.update!(Ecto.Changeset.change(connection, last_success_at: Budget.now()))
        :applied

      :absent ->
        if purpose == :cleanup and operation != :reconcile do
          # A 404 for one immutable ID proves only that object's absence.
          # Graph duplicate/continuation obligations require a scoped marker
          # reconciliation with no continuation before owner completion.
          retry!(command, "removal_accepted_verify", 2)
          throw({:calendar_retained_pending, :removal_pending_verification})
        end

        if purpose == :cleanup do
          Repo.update!(
            Ecto.Changeset.change(mapping,
              status: :absent,
              verified_at: Budget.now(),
              external_identity_box: nil,
              etag_box: nil,
              duplicate_identities_box: nil
            )
          )

          finish!(command)
          # The retained Governance and Connection fences precede this fresh,
          # same-principal absence proof. Older queued/uncertain intents cannot
          # cross those fences and are terminal only after the proof commits.
          Repo.update_all(
            from(c in SyncCommand,
              where:
                c.mapping_id == ^mapping.id and
                  c.consent_generation <= ^connection.consent_generation
            ),
            set: [status: :done, completed_at: Budget.now(), safe_reason: nil]
          )

          refresh_export!(export)
          maybe_revoke!(connection)
          :verified_absent
        else
          finish!(command)

          if command.safe_reason == "explicit_reexport_current" do
            verified_mapping = mark_reexport_absence!(mapping)
            Commands.create_after_verified_absence!(connection, verified_mapping)
          else
            if command.operation == :reconcile and command.attempt == 1 and
                 is_nil(mapping.external_identity_box) do
              Commands.insert!(connection, mapping, :create)
            else
              Repo.update!(Ecto.Changeset.change(mapping, status: :conflict))

              Repo.update!(
                Ecto.Changeset.change(export, status: :conflict, safe_reason: "external_removed")
              )
            end
          end

          :absent
        end

      :removal_accepted ->
        retry!(command, "removal_accepted_verify", 2)
        :removal_pending_verification

      :duplicate ->
        Repo.update!(
          Ecto.Changeset.change(mapping,
            duplicate_identities_box:
              Boxes.encrypt!(%{ids: receipt.verified_ids}, mapping_context(connection, mapping)),
            status: if(purpose == :cleanup, do: :removing, else: :conflict)
          )
        )

        if purpose == :cleanup,
          do: retry!(command, "provider_duplicates_pending", 2),
          else:
            (
              block!(command, "provider_duplicates")

              Repo.update!(
                Ecto.Changeset.change(export,
                  status: :conflict,
                  safe_reason: "provider_duplicates"
                )
              )
            )

        :duplicate_pending

      :conflict ->
        block!(command, "external_changed")
        Repo.update!(Ecto.Changeset.change(mapping, status: :conflict))

        Repo.update!(
          Ecto.Changeset.change(export, status: :conflict, safe_reason: "external_changed")
        )

        :conflict

      outcome when outcome in [:denied, :reauthorization_required] ->
        block!(command, "provider_permission_required")

        Repo.update!(
          Ecto.Changeset.change(connection,
            status: :reauthorization_required,
            fenced_at: connection.fenced_at || Budget.now(),
            safe_reason: "cleanup_reauthorization_required"
          )
        )

        :permission_pending

      :retryable ->
        retry!(
          command,
          "provider_retryable",
          receipt.retry_after_seconds || backoff(command.attempt)
        )

        :retryable

      _ ->
        Repo.update!(
          Ecto.Changeset.change(command,
            status: :uncertain,
            safe_reason: "effect_acknowledgement_unknown",
            available_at: DateTime.add(Budget.now(), backoff(command.attempt))
          )
        )

        Repo.update!(
          Ecto.Changeset.change(export,
            status: :uncertain,
            safe_reason: "effect_acknowledgement_unknown"
          )
        )

        :uncertain
    end
  end

  defp mark_reexport_absence!(%EventMapping{} = mapping),
    do:
      Repo.update!(
        Ecto.Changeset.change(mapping,
          status: :unknown,
          verified_at: Budget.now(),
          external_identity_box: nil,
          etag_box: nil,
          duplicate_identities_box: nil
        )
      )

  defp revoke!(connection, credentials, command, deadline) do
    pending =
      Repo.exists?(
        from(m in EventMapping,
          where:
            m.connection_id == ^connection.id and
              (m.status != :absent or is_nil(m.verified_at))
        )
      )

    live_intents =
      Repo.exists?(
        from(c in SyncCommand,
          where:
            c.connection_id == ^connection.id and
              c.id != ^command.id and c.status in ^@active and not is_nil(c.mapping_id)
        )
      )

    if pending or live_intents, do: Repo.rollback(:calendar_cleanup_pending)

    case ProviderAdapter.revoke(connection.provider, credentials["refresh_token"], deadline) do
      {:ok, result} when result in [:confirmed, :external_unconfirmed] ->
        Repo.update!(
          Ecto.Changeset.change(connection,
            status: :removed,
            fenced_at: connection.fenced_at || Budget.now(),
            credentials_box: nil,
            external_identity_box: nil,
            access_expires_at: nil,
            credential_destroyed_at: Budget.now(),
            provider_grant_revocation: result,
            safe_reason:
              if(result == :external_unconfirmed, do: "provider_grant_revocation_unconfirmed"),
            version: connection.version + 1
          )
        )

        finish!(command)
        :local_credentials_destroyed

      _ ->
        retry!(command, "provider_revocation_pending", backoff(command.attempt))
        :revocation_pending
    end
  end

  defp refresh_export!(export) do
    mappings = Repo.all(from(m in EventMapping, where: m.export_id == ^export.id))

    if mappings != [] and
         Enum.all?(mappings, &(&1.status == :absent and not is_nil(&1.verified_at))) and
         export.tombstoned_at do
      Repo.update!(Ecto.Changeset.change(export, status: :removed, removed_at: Budget.now()))
    else
      if mappings != [] and
           Enum.all?(
             mappings,
             &(&1.status == :present and
                 &1.applied_meeting_version == export.desired_meeting_version)
           ) do
        Repo.update!(
          Ecto.Changeset.change(export,
            status: :synced,
            applied_meeting_version: export.desired_meeting_version
          )
        )
      end
    end
  end

  defp maybe_revoke!(connection) do
    if not is_nil(connection.fenced_at) and
         not Repo.exists?(
           from(m in EventMapping,
             where: m.connection_id == ^connection.id and m.status != :absent
           )
         ),
       do: Commands.insert!(connection, nil, :revoke)
  end

  defp mapping_context(connection, mapping),
    do: %SecretContext{
      tenant_id: connection.tenant_id,
      user_id: connection.user_id,
      provider: connection.provider,
      resource_id: mapping.id,
      generation: mapping.sync_generation,
      purpose: :event_identity
    }

  defp finish!(command),
    do:
      Repo.update!(
        Ecto.Changeset.change(command,
          status: :done,
          completed_at: Budget.now(),
          safe_reason: nil
        )
      )

  defp block!(command, reason),
    do: Repo.update!(Ecto.Changeset.change(command, status: :blocked, safe_reason: reason))

  defp retry!(command, reason, seconds),
    do:
      Repo.update!(
        Ecto.Changeset.change(command,
          status: :retryable,
          safe_reason: reason,
          available_at: DateTime.add(Budget.now(), min(max(seconds, 1), 3600))
        )
      )

  defp backoff(attempt), do: min(3600, trunc(:math.pow(2, min(attempt, 11))) + :rand.uniform(5))

  defp uncertain_after_abort(claimed) do
    Repo.update_all(
      from(c in SyncCommand,
        where: c.id == ^claimed.id and c.lease_id == ^claimed.lease_id and c.status == :leased
      ),
      set: [
        status: :uncertain,
        safe_reason: "effect_acknowledgement_unknown",
        available_at: DateTime.add(Budget.now(), 5)
      ]
    )
  end
end
