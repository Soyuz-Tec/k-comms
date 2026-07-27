defmodule CommsCore.Release do
  @app :comms_core

  alias CommsCore.{
    Accounts,
    Administration,
    Attachments,
    AudioCalls,
    Audit,
    Conversations,
    Messaging,
    Outbox,
    Repo,
    RuntimePorts
  }

  alias CommsCore.Attachments.{RestoreCandidate, RestoreContext, RestoredObjectIdentity}

  @restore_remap_confirmation "remap-restored-attachment-versions"
  @qualification_confirmation "local-release-qualification-tenant-v1"
  @qualification_id_pattern ~r/\A[0-9a-f]{32}\z/
  @instant_room_fingerprint_confirmation "fixed-instant-room-tenant-fingerprint-v1"
  @instant_room_tenant_slug_pattern ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  @instant_room_fingerprint_categories [
    :users,
    :sessions,
    :devices,
    :conversations,
    :memberships,
    :messages,
    :guest_links,
    :guest_admissions,
    :ephemeral_rooms,
    :ephemeral_presence_leases,
    :ephemeral_join_receipts,
    :audit_events,
    :outbox_events,
    :calls,
    :call_participants
  ]
  @guest_rollback_capabilities MapSet.new([
                                 "guest_identity_v1",
                                 "guest_admission_expiry_worker_v1"
                               ])
  @instant_room_rollback_capabilities MapSet.new([
                                        "instant_room_lifecycle_v1",
                                        "instant_room_presence_lease_v1",
                                        "instant_room_expiry_worker_v1",
                                        "conversation_only_human_v1"
                                      ])
  @communication_rollback_capabilities MapSet.union(
                                         @guest_rollback_capabilities,
                                         @instant_room_rollback_capabilities
                                       )
  @migration_lock_timeout_default_ms 5_000
  @migration_lock_timeout_range 1_000..30_000
  @migration_statement_timeout_default_ms 300_000
  @migration_statement_timeout_range 60_000..900_000
  @one_shot_database_client_prefix "k_comms/one_shot/"
  @release_target_identifier ~r/\A[A-Za-z0-9][A-Za-z0-9._:@+\/-]{0,254}\z/

  def migrate do
    with {:ok, settings} <- validate_migration_environment(&System.get_env/1) do
      load_app()

      for repo <- Application.fetch_env!(@app, :ecto_repos) do
        {:ok, _, _} =
          Ecto.Migrator.with_repo(repo, fn repo ->
            assert_migration_preflight!(repo, settings)
            Ecto.Migrator.run(repo, :up, all: true)
          end)
      end
    else
      {:error, reason} -> raise "release migration refused: #{migration_error(reason)}"
    end
  end

  @doc """
  Refuses release-driven schema down-migrations.

  Application rollback restores a previously qualified image only after its
  compatibility preflight. Database recovery uses a verified backup or an
  explicitly reviewed forward repair; a down migration cannot reconstruct
  deleted or transformed business data.
  """
  @spec rollback(module(), integer()) :: no_return()
  def rollback(_repo, _version) do
    raise "release schema rollback refused: down migrations are unsupported; " <>
            "restore a verified backup or apply an explicitly reviewed forward repair"
  end

  @doc """
  Refuses activation of a guest-incompatible rollback target while guest state
  or runnable guest-expiry work remains.

  The operation is one-shot only. A target that declares both guest rollback
  capabilities is accepted without a database probe. Every other target is
  accepted only after all other database clients have stopped and PostgreSQL
  reports zero persisted guest users and zero active guest-expiry jobs.
  """
  @spec assert_guest_rollback_compatible!() :: :ok
  def assert_guest_rollback_compatible! do
    with {:ok, context} <-
           validate_guest_rollback_environment(&System.get_env/1) do
      if guest_rollback_capable?(context.capabilities) do
        IO.puts(
          "Guest rollback target #{context.target_revision} " <>
            "declares the required compatibility capabilities"
        )

        :ok
      else
        load_app()

        {:ok, hazards, _started_apps} =
          Ecto.Migrator.with_repo(Repo, fn repo ->
            assert_database_quiesced!(repo)

            guest_rollback_hazards(repo)
            |> assert_guest_rollback_hazards!(context)
          end)

        IO.puts(
          "Guest rollback preflight passed for #{context.target_revision}: " <>
            "guest_users=#{hazards.guest_users} " <>
            "active_guest_expiry_jobs=#{hazards.active_guest_expiry_jobs}"
        )

        :ok
      end
    else
      {:error, reason} ->
        raise "guest rollback compatibility check refused: #{migration_error(reason)}"
    end
  end

  @doc false
  def assert_guest_rollback_compatible, do: assert_guest_rollback_compatible!()

  @doc """
  Refuses activation of a communication-incompatible rollback target while
  persisted guest or instant-room state, bounded join receipts, presence leases,
  or runnable lifecycle work requires capabilities that the target does not
  declare.

  A target carrying every communication rollback capability is accepted without
  a database probe. Partial and legacy targets require all application writers
  to be stopped. The one-shot operation then proves exclusive database access
  and fails closed for each unsupported persisted-state or worker-job hazard.
  """
  @spec assert_communication_rollback_compatible!() :: :ok
  def assert_communication_rollback_compatible! do
    with {:ok, context} <-
           validate_communication_rollback_environment(&System.get_env/1) do
      if communication_rollback_capable?(context.capabilities) do
        IO.puts(
          "Communication rollback target #{context.target_revision} " <>
            "declares the required compatibility capabilities"
        )

        :ok
      else
        load_app()

        {:ok, hazards, _started_apps} =
          Ecto.Migrator.with_repo(Repo, fn repo ->
            assert_database_quiesced!(repo)

            communication_rollback_hazards(repo)
            |> assert_communication_rollback_hazards!(context)
          end)

        IO.puts(
          "Communication rollback preflight passed for #{context.target_revision}: " <>
            "guest_users=#{hazards.guest_users} " <>
            "active_guest_expiry_jobs=#{hazards.active_guest_expiry_jobs} " <>
            "ephemeral_rooms=#{hazards.ephemeral_rooms} " <>
            "ephemeral_join_receipts=#{hazards.ephemeral_join_receipts} " <>
            "ephemeral_presence_leases=#{hazards.ephemeral_presence_leases} " <>
            "active_ephemeral_room_lifecycle_jobs=" <>
            "#{hazards.active_ephemeral_room_lifecycle_jobs} " <>
            "active_ephemeral_room_reconciler_jobs=" <>
            "#{hazards.active_ephemeral_room_reconciler_jobs} " <>
            "conversation_only_humans=#{hazards.conversation_only_humans}"
        )

        :ok
      end
    else
      {:error, reason} ->
        raise "communication rollback compatibility check refused: #{migration_error(reason)}"
    end
  end

  @doc false
  def assert_communication_rollback_compatible,
    do: assert_communication_rollback_compatible!()

  def bootstrap do
    load_app()

    attrs = %{
      tenant_name: System.fetch_env!("BOOTSTRAP_TENANT_NAME"),
      tenant_slug: System.fetch_env!("BOOTSTRAP_TENANT_SLUG"),
      display_name: System.fetch_env!("BOOTSTRAP_OWNER_DISPLAY_NAME"),
      email: System.fetch_env!("BOOTSTRAP_OWNER_EMAIL"),
      password: System.fetch_env!("BOOTSTRAP_OWNER_PASSWORD")
    }

    {:ok, result, _started_apps} =
      Ecto.Migrator.with_repo(Repo, fn _repo -> Accounts.bootstrap_tenant_once(attrs) end)

    case result do
      {:ok, %{status: status, tenant: tenant}} when status in [:created, :existing] ->
        IO.puts("Tenant bootstrap #{status}: #{tenant.slug}")
        :ok

      {:error, reason} ->
        raise "tenant bootstrap failed: #{bootstrap_error(reason)}"
    end
  end

  @doc """
  Creates or deletes one isolated local-release qualification tenant.

  The command is available only to an identified one-shot runtime with the
  exact confirmation value. All tenant identity fields are derived from a
  random 128-bit lowercase hexadecimal qualification id, so the command cannot
  target an operator-created tenant.
  """
  def qualification_tenant do
    with {:ok, context} <-
           validate_qualification_environment(&System.get_env/1) do
      load_app()

      {:ok, result, _started_apps} =
        Ecto.Migrator.with_repo(Repo, fn _repo ->
          case context.action do
            :create -> Accounts.bootstrap_tenant(context.attrs)
            :delete -> Accounts.delete_release_qualification_tenant(context.attrs)
          end
        end)

      case result do
        {:ok, %{tenant: tenant}} ->
          IO.puts("Release qualification tenant #{context.action} completed: #{tenant.slug}")

          :ok

        {:ok, %{status: :absent, tenant_slug: tenant_slug}} ->
          IO.puts("Release qualification tenant already absent: #{tenant_slug}")
          :ok

        {:error, reason} ->
          raise "release qualification tenant operation failed: " <>
                  qualification_error(reason)
      end
    else
      {:error, reason} ->
        raise "release qualification tenant operation refused: " <>
                qualification_error(reason)
    end
  end

  @doc """
  Prints a content-free fingerprint of the configured fixed instant-room tenant.

  The command is read-only and available only to an identified one-shot runtime
  carrying the dedicated confirmation value. Output contains only tenant
  presence, per-category row counts, and a SHA-256 digest over sorted internal
  row identities. Tenant slugs, row IDs, secrets, and business content are
  never printed.
  """
  @spec instant_room_tenant_fingerprint() :: :ok
  def instant_room_tenant_fingerprint do
    with {:ok, context} <-
           validate_instant_room_fingerprint_environment(&System.get_env/1) do
      load_app()

      {:ok, report, _started_apps} =
        Ecto.Migrator.with_repo(Repo, fn repo ->
          instant_room_tenant_fingerprint(repo, context.tenant_slug)
        end)

      IO.puts(format_instant_room_tenant_fingerprint(report))
      :ok
    else
      {:error, reason} ->
        raise "instant-room tenant fingerprint refused: " <>
                instant_room_fingerprint_error(reason)
    end
  end

  @doc """
  Verifies restored attachment objects and atomically remaps their version IDs.

  This is an explicit disaster-recovery operation. It is unavailable to the
  normal application runtime and requires the documented one-shot environment
  confirmation plus an operation ID, actor, and reason for the audit ledger.
  """
  @spec remap_restored_attachment_versions((RestoreCandidate.t() ->
                                              {:ok, RestoredObjectIdentity.t()} | {:error, term()})) ::
          :ok
  def remap_restored_attachment_versions(verifier) when is_function(verifier, 1) do
    with {:ok, context} <- validate_restore_remap_environment(&System.get_env/1) do
      load_app()

      {:ok, result, _started_apps} =
        Ecto.Migrator.with_repo(Repo, fn _repo ->
          Attachments.remap_restored_attachment_versions(verifier, context)
        end)

      case result do
        {:ok, report} ->
          IO.puts(
            "Attachment restore remap completed: " <>
              "candidates=#{report.candidate_count} " <>
              "verified=#{report.verified_count} " <>
              "remapped=#{report.remapped_count} " <>
              "unchanged=#{report.unchanged_count} " <>
              "etag_matched=#{report.trustworthy_etag_count} " <>
              "etag_untrusted=#{report.untrusted_etag_count} " <>
              "unversioned_fail_closed=#{report.unversioned_fail_closed_count} " <>
              "tenants=#{report.tenant_count}"
          )

          :ok

        {:error, {:verification_failed, attachment_id, reason}} ->
          raise "attachment restore remap aborted before database update: " <>
                  "attachment=#{attachment_id} reason=#{restore_error(reason)}"

        {:error, reason} ->
          raise "attachment restore remap failed: #{restore_error(reason)}"
      end
    else
      {:error, reason} -> raise "attachment restore remap refused: #{restore_error(reason)}"
    end
  end

  @doc false
  def validate_restore_remap_environment(get_env) when is_function(get_env, 1) do
    runtime_purpose = get_env.("K_COMMS_RUNTIME_PURPOSE")
    confirmation = get_env.("K_COMMS_RESTORE_VERSION_REMAP")
    operation_id = get_env.("K_COMMS_RESTORE_OPERATION_ID")
    actor = get_env.("K_COMMS_RESTORE_ACTOR")
    reason = get_env.("K_COMMS_RESTORE_REASON")

    cond do
      runtime_purpose != "one_shot" ->
        {:error, :one_shot_runtime_required}

      confirmation != @restore_remap_confirmation ->
        {:error, :restore_remap_confirmation_required}

      not valid_uuid?(operation_id) ->
        {:error, :restore_operation_id_required}

      not safe_audit_text?(actor, 255) ->
        {:error, :restore_actor_required}

      not safe_audit_text?(reason, 500) ->
        {:error, :restore_reason_required}

      true ->
        {:ok,
         %RestoreContext{
           operation_id: operation_id,
           actor: String.trim(actor),
           reason: String.trim(reason)
         }}
    end
  end

  @doc false
  def validate_migration_environment(get_env) when is_function(get_env, 1) do
    with :ok <- require_one_shot(get_env),
         :ok <- require_migration_quiescence(get_env),
         {:ok, lock_timeout_ms} <-
           parse_bounded_timeout(
             get_env.("K_COMMS_MIGRATION_LOCK_TIMEOUT_MS"),
             @migration_lock_timeout_default_ms,
             @migration_lock_timeout_range,
             :migration_lock_timeout_invalid
           ),
         {:ok, statement_timeout_ms} <-
           parse_bounded_timeout(
             get_env.("K_COMMS_MIGRATION_STATEMENT_TIMEOUT_MS"),
             @migration_statement_timeout_default_ms,
             @migration_statement_timeout_range,
             :migration_statement_timeout_invalid
           ),
         :ok <- validate_timeout_order(lock_timeout_ms, statement_timeout_ms) do
      {:ok,
       %{
         lock_timeout_ms: lock_timeout_ms,
         statement_timeout_ms: statement_timeout_ms
       }}
    end
  end

  @doc false
  def validate_qualification_environment(get_env) when is_function(get_env, 1) do
    with :ok <- require_one_shot(get_env),
         :ok <- require_qualification_confirmation(get_env),
         {:ok, action} <- qualification_action(get_env.("K_COMMS_QUALIFICATION_ACTION")),
         {:ok, qualification_id} <-
           qualification_id(get_env.("K_COMMS_QUALIFICATION_ID")),
         :ok <-
           require_qualification_password(
             action,
             get_env.("K_COMMS_QUALIFICATION_PASSWORD")
           ) do
      {:ok,
       %{
         action: action,
         attrs: %{
           tenant_name: "K-Comms qualification #{qualification_id}",
           tenant_slug: "k-comms-qualification-#{qualification_id}",
           display_name: "K-Comms Qualification Owner",
           email: "k-comms-qualification-owner+#{qualification_id}@example.test",
           password: get_env.("K_COMMS_QUALIFICATION_PASSWORD")
         }
       }}
    end
  end

  @doc false
  def validate_instant_room_fingerprint_environment(get_env)
      when is_function(get_env, 1) do
    with :ok <- require_one_shot(get_env),
         :ok <- require_instant_room_fingerprint_confirmation(get_env),
         {:ok, tenant_slug} <-
           validate_instant_room_fingerprint_tenant_slug(get_env.("INSTANT_ROOM_TENANT_SLUG")) do
      {:ok, %{tenant_slug: tenant_slug}}
    end
  end

  @doc false
  def instant_room_tenant_fingerprint_categories do
    @instant_room_fingerprint_categories
  end

  @doc false
  def instant_room_tenant_fingerprint(repo, tenant_slug)
      when is_atom(repo) and is_binary(tenant_slug) do
    case Administration.release_tenant_fingerprint_id(repo, tenant_slug) do
      nil ->
        build_instant_room_tenant_fingerprint(nil, %{})

      tenant_id ->
        fragments = [
          Accounts.release_tenant_fingerprint_fragment(repo, tenant_id),
          Conversations.release_tenant_fingerprint_fragment(repo, tenant_id),
          Messaging.release_tenant_fingerprint_fragment(repo, tenant_id),
          Audit.release_tenant_fingerprint_fragment(repo, tenant_id),
          Outbox.release_tenant_fingerprint_fragment(repo, tenant_id),
          AudioCalls.release_tenant_fingerprint_fragment(repo, tenant_id)
        ]

        build_instant_room_tenant_fingerprint(
          tenant_id,
          merge_instant_room_fingerprint_fragments(fragments)
        )
    end
  end

  @doc false
  def format_instant_room_tenant_fingerprint(%{
        version: 1,
        tenant_present: tenant_present,
        counts: counts,
        fingerprint_sha256: fingerprint
      })
      when is_boolean(tenant_present) and is_map(counts) and is_binary(fingerprint) do
    count_fields =
      Enum.map_join(@instant_room_fingerprint_categories, " ", fn category ->
        "#{category}=#{Map.fetch!(counts, category)}"
      end)

    "K_COMMS_INSTANT_ROOM_TENANT_FINGERPRINT_V1 " <>
      "tenant_present=#{tenant_present} #{count_fields} " <>
      "fingerprint_sha256=#{fingerprint}"
  end

  @doc false
  def validate_guest_rollback_environment(get_env) when is_function(get_env, 1) do
    validate_rollback_environment(get_env, &guest_rollback_capable?/1)
  end

  @doc false
  def validate_communication_rollback_environment(get_env)
      when is_function(get_env, 1) do
    validate_rollback_environment(get_env, &communication_rollback_capable?/1)
  end

  @doc false
  def assert_migration_preflight!(repo, settings) when is_atom(repo) and is_map(settings) do
    rows = repo.release_migration_preflight!()

    assert_migration_preflight_result!(rows, settings)
  end

  @doc false
  def assert_migration_preflight_result!(
        [
          [
            application_name,
            actual_lock_timeout_ms,
            actual_statement_timeout_ms,
            peer_count
          ]
        ],
        %{
          lock_timeout_ms: expected_lock_timeout_ms,
          statement_timeout_ms: expected_statement_timeout_ms
        }
      )
      when is_binary(application_name) and is_integer(actual_lock_timeout_ms) and
             is_integer(actual_statement_timeout_ms) and is_integer(peer_count) do
    assert_one_shot_database_client!(application_name)

    if actual_lock_timeout_ms != expected_lock_timeout_ms do
      raise "migration preflight failed: PostgreSQL lock_timeout is not the configured bounded value"
    end

    if actual_statement_timeout_ms != expected_statement_timeout_ms do
      raise "migration preflight failed: PostgreSQL statement_timeout is not the configured bounded value"
    end

    assert_peer_count_quiesced!(peer_count)
  end

  def assert_migration_preflight_result!(_rows, _settings) do
    raise "migration preflight failed: PostgreSQL returned an invalid session snapshot"
  end

  @doc false
  def assert_database_quiesced!(repo \\ Repo) when is_atom(repo) do
    rows = repo.release_migration_preflight!()

    assert_database_quiescence_result!(rows)
  end

  @doc false
  def assert_database_quiescence_result!([
        [application_name, _lock_timeout_ms, _statement_timeout_ms, peer_count]
      ])
      when is_binary(application_name) and is_integer(peer_count) do
    assert_one_shot_database_client!(application_name)
    assert_peer_count_quiesced!(peer_count)
  end

  def assert_database_quiescence_result!(_rows) do
    raise "database quiescence check failed: PostgreSQL returned an invalid session snapshot"
  end

  @doc false
  def assert_guest_rollback_hazards!(
        %{
          guest_users: guest_users,
          active_guest_expiry_jobs: active_guest_expiry_jobs
        },
        %{
          capabilities: %MapSet{} = capabilities,
          target_revision: target_revision
        }
      )
      when is_integer(guest_users) and guest_users >= 0 and
             is_integer(active_guest_expiry_jobs) and active_guest_expiry_jobs >= 0 and
             is_binary(target_revision) do
    if guest_rollback_capable?(capabilities) or
         (guest_users == 0 and active_guest_expiry_jobs == 0) do
      %{
        guest_users: guest_users,
        active_guest_expiry_jobs: active_guest_expiry_jobs
      }
    else
      raise "guest rollback compatibility check blocked: " <>
              "target #{target_revision} lacks guest_identity_v1 and " <>
              "guest_admission_expiry_worker_v1 while PostgreSQL contains " <>
              "#{guest_users} persisted guest user row(s) and " <>
              "#{active_guest_expiry_jobs} active guest expiry job(s); " <>
              "retain or deploy a guest-compatible bridge release, or roll forward"
    end
  end

  def assert_guest_rollback_hazards!(_rows, _capabilities) do
    raise "guest rollback compatibility check failed: PostgreSQL returned an invalid hazard snapshot"
  end

  @doc false
  def assert_communication_rollback_hazards!(
        %{
          guest_users: guest_users,
          active_guest_expiry_jobs: active_guest_expiry_jobs,
          ephemeral_rooms: ephemeral_rooms,
          ephemeral_join_receipts: ephemeral_join_receipts,
          ephemeral_presence_leases: ephemeral_presence_leases,
          active_ephemeral_room_lifecycle_jobs: active_ephemeral_room_lifecycle_jobs,
          active_ephemeral_room_reconciler_jobs: active_ephemeral_room_reconciler_jobs,
          conversation_only_humans: conversation_only_humans
        } = hazards,
        %{
          capabilities: %MapSet{} = capabilities,
          target_revision: target_revision
        }
      )
      when is_integer(guest_users) and guest_users >= 0 and
             is_integer(active_guest_expiry_jobs) and active_guest_expiry_jobs >= 0 and
             is_integer(ephemeral_rooms) and ephemeral_rooms >= 0 and
             is_integer(ephemeral_join_receipts) and ephemeral_join_receipts >= 0 and
             is_integer(ephemeral_presence_leases) and ephemeral_presence_leases >= 0 and
             is_integer(active_ephemeral_room_lifecycle_jobs) and
             active_ephemeral_room_lifecycle_jobs >= 0 and
             is_integer(active_ephemeral_room_reconciler_jobs) and
             active_ephemeral_room_reconciler_jobs >= 0 and
             is_integer(conversation_only_humans) and conversation_only_humans >= 0 and
             is_binary(target_revision) do
    unsupported_hazards =
      [
        {"guest_identity_v1", guest_users},
        {"guest_admission_expiry_worker_v1", active_guest_expiry_jobs},
        {"instant_room_lifecycle_v1", ephemeral_rooms + ephemeral_join_receipts},
        {"instant_room_presence_lease_v1", ephemeral_presence_leases},
        {"instant_room_expiry_worker_v1",
         active_ephemeral_room_lifecycle_jobs + active_ephemeral_room_reconciler_jobs},
        {"conversation_only_human_v1", conversation_only_humans}
      ]
      |> Enum.filter(fn {capability, count} ->
        count > 0 and not MapSet.member?(capabilities, capability)
      end)

    if unsupported_hazards == [] do
      hazards
    else
      missing_capabilities =
        unsupported_hazards
        |> Enum.map_join(", ", fn {capability, _count} -> capability end)

      raise "communication rollback compatibility check blocked: " <>
              "target #{target_revision} lacks #{missing_capabilities} while PostgreSQL contains " <>
              "guest_users=#{guest_users}, " <>
              "active_guest_expiry_jobs=#{active_guest_expiry_jobs}, " <>
              "ephemeral_rooms=#{ephemeral_rooms}, " <>
              "ephemeral_join_receipts=#{ephemeral_join_receipts}, " <>
              "ephemeral_presence_leases=#{ephemeral_presence_leases}, " <>
              "active_ephemeral_room_lifecycle_jobs=" <>
              "#{active_ephemeral_room_lifecycle_jobs}, " <>
              "active_ephemeral_room_reconciler_jobs=" <>
              "#{active_ephemeral_room_reconciler_jobs}, " <>
              "conversation_only_humans=#{conversation_only_humans}; " <>
              "retain or deploy a compatible bridge release, or roll forward"
    end
  end

  def assert_communication_rollback_hazards!(_rows, _capabilities) do
    raise "communication rollback compatibility check failed: " <>
            "PostgreSQL returned an invalid hazard snapshot"
  end

  @doc """
  Grants or revokes a platform role through the release console boundary.

  `K_COMMS_PLATFORM_ROLE_MANAGEMENT_SECRET` must already be configured for the
  running release. The caller must separately provide the matching
  `K_COMMS_PLATFORM_ROLE_GRANT_TOKEN`, plus explicit actor and reason variables.
  Grants require `K_COMMS_PLATFORM_ROLE_TTL_SECONDS` from 300 through 28,800
  seconds. Use `none` as the role to revoke access; revocation does not require a
  TTL.
  """
  def set_platform_role(user_id, role) do
    ttl_seconds = platform_role_ttl_env(role)

    set_platform_role(
      user_id,
      role,
      System.fetch_env!("K_COMMS_PLATFORM_ROLE_GRANT_TOKEN"),
      System.fetch_env!("K_COMMS_PLATFORM_ROLE_ACTOR"),
      System.fetch_env!("K_COMMS_PLATFORM_ROLE_REASON"),
      ttl_seconds
    )
  end

  def set_platform_role(user_id, role, grant_token, actor, reason) do
    set_platform_role(user_id, role, grant_token, actor, reason, platform_role_ttl_env(role))
  end

  def set_platform_role(user_id, role, grant_token, actor, reason, ttl_seconds) do
    load_app()

    attrs = %{
      grant_token: grant_token,
      actor: actor,
      reason: reason,
      ttl_seconds: ttl_seconds
    }

    {:ok, result, _started_apps} =
      Ecto.Migrator.with_repo(Repo, fn _repo ->
        Accounts.set_platform_role_from_console(user_id, role, attrs)
      end)

    case result do
      {:ok, user} ->
        status = if user.platform_role, do: "granted", else: "revoked"

        deadline =
          if user.platform_role_expires_at,
            do: " until #{DateTime.to_iso8601(user.platform_role_expires_at)}",
            else: ""

        IO.puts("Platform role #{status} for user #{user.id}#{deadline}")
        :ok

      {:error, reason} ->
        raise "platform role update failed: #{platform_role_error(reason)}"
    end
  end

  defp require_one_shot(get_env) do
    if get_env.("K_COMMS_RUNTIME_PURPOSE") == "one_shot",
      do: :ok,
      else: {:error, :one_shot_runtime_required}
  end

  defp require_qualification_confirmation(get_env) do
    if get_env.("K_COMMS_QUALIFICATION_CONFIRMATION") ==
         @qualification_confirmation,
       do: :ok,
       else: {:error, :qualification_confirmation_required}
  end

  defp require_instant_room_fingerprint_confirmation(get_env) do
    if get_env.("K_COMMS_INSTANT_ROOM_FINGERPRINT_CONFIRMATION") ==
         @instant_room_fingerprint_confirmation,
       do: :ok,
       else: {:error, :instant_room_fingerprint_confirmation_required}
  end

  defp validate_instant_room_fingerprint_tenant_slug(value) when is_binary(value) do
    if byte_size(value) in 2..80 and
         Regex.match?(@instant_room_tenant_slug_pattern, value),
       do: {:ok, value},
       else: {:error, :instant_room_tenant_slug_invalid}
  end

  defp validate_instant_room_fingerprint_tenant_slug(_value),
    do: {:error, :instant_room_tenant_slug_invalid}

  defp qualification_action("create"), do: {:ok, :create}
  defp qualification_action("delete"), do: {:ok, :delete}
  defp qualification_action(_value), do: {:error, :qualification_action_invalid}

  defp qualification_id(value) when is_binary(value) do
    if Regex.match?(@qualification_id_pattern, value),
      do: {:ok, value},
      else: {:error, :qualification_id_invalid}
  end

  defp qualification_id(_value), do: {:error, :qualification_id_invalid}

  defp require_qualification_password(:delete, _password), do: :ok

  defp require_qualification_password(:create, password)
       when is_binary(password) and byte_size(password) >= 16,
       do: :ok

  defp require_qualification_password(:create, _password),
    do: {:error, :qualification_password_required}

  defp require_migration_quiescence(get_env) do
    if get_env.("K_COMMS_MIGRATION_REQUIRE_QUIESCENCE") == "true",
      do: :ok,
      else: {:error, :migration_quiescence_confirmation_required}
  end

  defp parse_bounded_timeout(nil, default, _range, _error), do: {:ok, default}
  defp parse_bounded_timeout("", default, _range, _error), do: {:ok, default}

  defp parse_bounded_timeout(value, _default, range, error) when is_binary(value) do
    case Integer.parse(value) do
      {timeout, ""} -> if(timeout in range, do: {:ok, timeout}, else: {:error, error})
      _ -> {:error, error}
    end
  end

  defp parse_bounded_timeout(_value, _default, _range, error), do: {:error, error}

  defp validate_timeout_order(lock_timeout_ms, statement_timeout_ms)
       when statement_timeout_ms > lock_timeout_ms,
       do: :ok

  defp validate_timeout_order(_lock_timeout_ms, _statement_timeout_ms),
    do: {:error, :migration_statement_timeout_must_exceed_lock_timeout}

  defp assert_one_shot_database_client!(application_name) do
    unless String.starts_with?(application_name, @one_shot_database_client_prefix) do
      raise "database quiescence check failed: the connection is not an identified one-shot runtime"
    end
  end

  defp assert_peer_count_quiesced!(0), do: :ok

  defp assert_peer_count_quiesced!(peer_count) when peer_count > 0 do
    raise "database quiescence check failed: " <>
            "#{peer_count} other client session(s) remain connected; " <>
            "stop edge, worker, application, and other administrative runtimes before continuing"
  end

  defp guest_rollback_capable?(capabilities) do
    MapSet.subset?(@guest_rollback_capabilities, capabilities)
  end

  defp communication_rollback_capable?(capabilities) do
    MapSet.subset?(@communication_rollback_capabilities, capabilities)
  end

  defp validate_rollback_environment(get_env, compatible?)
       when is_function(get_env, 1) and is_function(compatible?, 1) do
    with :ok <- require_one_shot(get_env) do
      capabilities =
        get_env.("K_COMMS_ROLLBACK_TARGET_CAPABILITIES")
        |> to_string()
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> MapSet.new()

      target_revision = get_env.("K_COMMS_ROLLBACK_TARGET_REVISION")

      cond do
        not valid_release_target_identifier?(target_revision) ->
          {:error, :rollback_target_revision_required}

        not compatible?.(capabilities) and
            get_env.("K_COMMS_ROLLBACK_WRITES_QUIESCED") != "true" ->
          {:error, :rollback_writes_quiescence_confirmation_required}

        true ->
          {:ok,
           %{
             capabilities: capabilities,
             target_revision: target_revision
           }}
      end
    end
  end

  defp guest_rollback_hazards(repo) when is_atom(repo) do
    %{
      guest_users: Accounts.persisted_guest_identity_count(),
      active_guest_expiry_jobs:
        repo.active_oban_job_count!(RuntimePorts.job_worker_name!(:guest_admission_expiry))
    }
  end

  defp communication_rollback_hazards(repo) when is_atom(repo) do
    guest_rollback_hazards(repo)
    |> Map.merge(%{
      ephemeral_rooms: Conversations.persisted_ephemeral_room_count(),
      ephemeral_join_receipts: Conversations.persisted_ephemeral_join_receipt_count(),
      ephemeral_presence_leases: Conversations.persisted_ephemeral_presence_lease_count(),
      active_ephemeral_room_lifecycle_jobs:
        repo.active_oban_job_count!(RuntimePorts.job_worker_name!(:ephemeral_room_lifecycle)),
      active_ephemeral_room_reconciler_jobs:
        repo.active_oban_job_count!(RuntimePorts.job_worker_name!(:ephemeral_room_reconciler)),
      conversation_only_humans: Accounts.persisted_conversation_only_human_count()
    })
  end

  defp valid_release_target_identifier?(value) when is_binary(value),
    do: Regex.match?(@release_target_identifier, value)

  defp valid_release_target_identifier?(_value), do: false

  defp load_app do
    Application.load(@app)
  end

  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp valid_uuid?(_value), do: false

  defp safe_audit_text?(value, max) when is_binary(value) do
    value = String.trim(value)
    value != "" and byte_size(value) <= max
  end

  defp safe_audit_text?(_value, _max), do: false

  defp bootstrap_error(:weak_password), do: "owner password does not meet policy"

  defp bootstrap_error(:bootstrap_identity_conflict),
    do: "a different or incomplete tenant bootstrap already exists"

  defp bootstrap_error(%Ecto.Changeset{}), do: "bootstrap attributes are invalid"
  defp bootstrap_error(_reason), do: "database operation failed"

  defp qualification_error(:one_shot_runtime_required),
    do: "one_shot_runtime_required"

  defp qualification_error(:qualification_confirmation_required),
    do: "K_COMMS_QUALIFICATION_CONFIRMATION is invalid"

  defp qualification_error(:qualification_action_invalid),
    do: "K_COMMS_QUALIFICATION_ACTION must be create or delete"

  defp qualification_error(:qualification_id_invalid),
    do: "K_COMMS_QUALIFICATION_ID must be 32 lowercase hexadecimal characters"

  defp qualification_error(:qualification_password_required),
    do: "K_COMMS_QUALIFICATION_PASSWORD must contain at least 16 bytes for create"

  defp qualification_error(:weak_password),
    do: "the qualification owner password does not meet policy"

  defp qualification_error(:qualification_tenant_identity_conflict),
    do: "the qualification tenant identity marker does not match"

  defp qualification_error(%Ecto.Changeset{}),
    do: "qualification tenant attributes are invalid"

  defp qualification_error(_reason), do: "database operation failed"

  defp instant_room_fingerprint_error(:one_shot_runtime_required),
    do: "one_shot_runtime_required"

  defp instant_room_fingerprint_error(:instant_room_fingerprint_confirmation_required),
    do: "K_COMMS_INSTANT_ROOM_FINGERPRINT_CONFIRMATION is invalid"

  defp instant_room_fingerprint_error(:instant_room_tenant_slug_invalid),
    do: "INSTANT_ROOM_TENANT_SLUG is not a configured lowercase tenant slug"

  defp platform_role_error(:not_found), do: "active user was not found"
  defp platform_role_error(:invalid_platform_role), do: "platform role is invalid"

  defp platform_role_error(:platform_role_management_unavailable),
    do: "platform role management is not configured"

  defp platform_role_error(:invalid_platform_role_management_secret),
    do: "platform role authorization failed"

  defp platform_role_error(:platform_role_audit_context_required),
    do: "an explicit actor and reason are required"

  defp platform_role_error(:invalid_platform_role_ttl),
    do: "platform role TTL must be between 300 and 28800 seconds"

  defp platform_role_error(_reason), do: "database operation failed"

  defp platform_role_ttl_env(role) when role in [nil, "", "none", "revoke"], do: nil
  defp platform_role_ttl_env(_role), do: System.fetch_env!("K_COMMS_PLATFORM_ROLE_TTL_SECONDS")

  defp restore_error(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp restore_error({:object_storage_status, status}) when is_integer(status),
    do: "object_storage_status_#{status}"

  defp restore_error({:missing_s3_config, key}) when is_atom(key),
    do: "missing_s3_config_#{key}"

  defp restore_error(_reason), do: "restore_operation_failed"

  defp migration_error(:one_shot_runtime_required), do: "one_shot_runtime_required"

  defp migration_error(:migration_quiescence_confirmation_required),
    do: "K_COMMS_MIGRATION_REQUIRE_QUIESCENCE must be true"

  defp migration_error(:migration_lock_timeout_invalid),
    do: "K_COMMS_MIGRATION_LOCK_TIMEOUT_MS must be an integer from 1000 through 30000"

  defp migration_error(:migration_statement_timeout_invalid),
    do: "K_COMMS_MIGRATION_STATEMENT_TIMEOUT_MS must be an integer from 60000 through 900000"

  defp migration_error(:migration_statement_timeout_must_exceed_lock_timeout),
    do: "K_COMMS_MIGRATION_STATEMENT_TIMEOUT_MS must exceed K_COMMS_MIGRATION_LOCK_TIMEOUT_MS"

  defp migration_error(:rollback_target_revision_required),
    do: "K_COMMS_ROLLBACK_TARGET_REVISION must contain a safe target revision identifier"

  defp migration_error(:rollback_writes_quiescence_confirmation_required),
    do: "K_COMMS_ROLLBACK_WRITES_QUIESCED must be true for a guest-incompatible target"

  defp migration_error(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp merge_instant_room_fingerprint_fragments(fragments) when is_list(fragments) do
    identities_by_category =
      Enum.reduce(fragments, %{}, fn fragment, acc ->
        Enum.reduce(fragment, acc, fn
          {category, identities}, inner_acc
          when category in @instant_room_fingerprint_categories and is_list(identities) ->
            if Map.has_key?(inner_acc, category) or
                 not Enum.all?(identities, &is_binary/1) do
              raise "instant-room tenant fingerprint failed: invalid owner fragment"
            end

            Map.put(inner_acc, category, identities)

          _invalid_entry, _inner_acc ->
            raise "instant-room tenant fingerprint failed: invalid owner fragment"
        end)
      end)

    if Map.keys(identities_by_category) |> MapSet.new() ==
         MapSet.new(@instant_room_fingerprint_categories) do
      identities_by_category
    else
      raise "instant-room tenant fingerprint failed: incomplete owner fragments"
    end
  end

  defp build_instant_room_tenant_fingerprint(tenant_id, identities_by_category)
       when is_map(identities_by_category) do
    counts =
      Map.new(@instant_room_fingerprint_categories, fn category ->
        identities =
          identities_by_category
          |> Map.get(category, [])
          |> Enum.sort()

        {category, length(identities)}
      end)

    canonical =
      [
        "version=1",
        "tenant=#{tenant_id || "absent"}"
        | Enum.map(@instant_room_fingerprint_categories, fn category ->
            identities =
              identities_by_category
              |> Map.get(category, [])
              |> Enum.sort()

            "#{category}=#{Enum.join(identities, ",")}"
          end)
      ]
      |> Enum.join("\n")

    %{
      version: 1,
      tenant_present: not is_nil(tenant_id),
      counts: counts,
      fingerprint_sha256:
        canonical
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
    }
  end
end
