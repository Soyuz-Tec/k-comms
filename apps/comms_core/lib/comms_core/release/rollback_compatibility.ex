defmodule CommsCore.Release.RollbackCompatibility do
  @moduledoc false

  alias CommsCore.{
    Accounts,
    AudioCalls,
    Conversations,
    Messaging,
    Repo,
    Release.Environment,
    Release.Migration,
    RuntimePorts,
    ServiceAccounts,
    Telephony,
    Whiteboards
  }

  @app :comms_core
  @communication_hazard_capabilities [
    {"guest_identity_v1", [:guest_users]},
    {"guest_admission_expiry_worker_v1", [:active_guest_expiry_jobs]},
    {"instant_room_lifecycle_v1", [:ephemeral_rooms, :ephemeral_join_receipts]},
    {"instant_room_presence_lease_v1", [:ephemeral_presence_leases]},
    {"instant_room_expiry_worker_v1",
     [:active_ephemeral_room_lifecycle_jobs, :active_ephemeral_room_reconciler_jobs]},
    {"conversation_only_human_v1", [:conversation_only_humans]},
    {"enterprise_identity_v1", [:enterprise_identities, :scim_credentials]},
    {"uc_artifact_lifecycle_v1", [:retained_call_artifacts, :active_artifact_jobs]},
    {"uc_voicemail_lifecycle_v1", [:voicemail_media, :active_voicemail_jobs]},
    {"uc_advanced_telephony_v1",
     [:advanced_controls, :active_control_jobs, :active_routing_jobs]},
    {"scheduled_meeting_lifecycle_v1", [:scheduled_meetings, :active_meeting_reminder_jobs]},
    {"rich_content_erasure_v1", [:rich_messages, :rich_whiteboards]}
  ]

  def assert_guest_rollback_compatible! do
    with {:ok, context} <- Environment.validate_guest_rollback(&System.get_env/1) do
      if Environment.guest_rollback_capable?(context.capabilities) do
        IO.puts(
          "Guest rollback target #{context.target_revision} " <>
            "declares the required compatibility capabilities"
        )

        :ok
      else
        load_app()

        {:ok, hazards, _started_apps} =
          Ecto.Migrator.with_repo(Repo, fn repo ->
            Migration.assert_database_quiesced!(repo)

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

  def assert_communication_rollback_compatible! do
    with {:ok, context} <- Environment.validate_communication_rollback(&System.get_env/1) do
      if Environment.communication_rollback_capable?(context.capabilities) do
        IO.puts(
          "Communication rollback target #{context.target_revision} " <>
            "declares the required compatibility capabilities"
        )

        :ok
      else
        load_app()

        {:ok, hazards, _started_apps} =
          Ecto.Migrator.with_repo(Repo, fn repo ->
            Migration.assert_database_quiesced!(repo)

            communication_rollback_hazards(repo)
            |> assert_communication_rollback_hazards!(context)
          end)

        IO.puts(
          "Communication rollback preflight passed for #{context.target_revision}: " <>
            format_hazards(hazards)
        )

        :ok
      end
    else
      {:error, reason} ->
        raise "communication rollback compatibility check refused: #{migration_error(reason)}"
    end
  end

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
    if Environment.guest_rollback_capable?(capabilities) or
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

  def assert_communication_rollback_hazards!(
        hazards,
        %{
          capabilities: %MapSet{} = capabilities,
          target_revision: target_revision
        }
      )
      when is_map(hazards) and is_binary(target_revision) do
    unless Enum.all?(hazard_keys(), fn key ->
             value = Map.get(hazards, key)
             is_integer(value) and value >= 0
           end) do
      invalid_hazard_snapshot!()
    end

    unsupported_hazards =
      @communication_hazard_capabilities
      |> Enum.filter(fn {capability, keys} ->
        Enum.any?(keys, &(Map.fetch!(hazards, &1) > 0)) and
          not MapSet.member?(capabilities, capability)
      end)

    if unsupported_hazards == [] do
      hazards
    else
      missing_capabilities =
        unsupported_hazards
        |> Enum.map_join(", ", fn {capability, _count} -> capability end)

      raise "communication rollback compatibility check blocked: " <>
              "target #{target_revision} lacks #{missing_capabilities} while PostgreSQL contains " <>
              format_hazards(hazards) <>
              "; " <>
              "retain or deploy a compatible bridge release, or roll forward"
    end
  end

  def assert_communication_rollback_hazards!(_rows, _capabilities) do
    invalid_hazard_snapshot!()
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
      conversation_only_humans: Accounts.persisted_conversation_only_human_count(),
      enterprise_identities: Accounts.rollback_enterprise_identity_hazard_count(),
      scim_credentials: ServiceAccounts.rollback_scim_credential_hazard_count(),
      retained_call_artifacts: AudioCalls.rollback_artifact_hazard_count(),
      active_artifact_jobs: active_job_count(repo, :call_artifact),
      voicemail_media: Telephony.rollback_voicemail_hazard_count(),
      active_voicemail_jobs: active_job_count(repo, :telephony_voicemail),
      advanced_controls: Telephony.rollback_control_hazard_count(),
      active_control_jobs: active_job_count(repo, :telephony_control),
      active_routing_jobs: active_job_count(repo, :telephony_routing),
      scheduled_meetings: AudioCalls.rollback_meeting_hazard_count(),
      active_meeting_reminder_jobs: active_job_count(repo, :meeting_reminder),
      rich_messages: Messaging.rollback_rich_content_hazard_count(),
      rich_whiteboards: Whiteboards.rollback_rich_content_hazard_count()
    })
  end

  defp active_job_count(repo, kind),
    do: repo.active_oban_job_count!(RuntimePorts.job_worker_name!(kind))

  defp hazard_keys,
    do: Enum.flat_map(@communication_hazard_capabilities, fn {_capability, keys} -> keys end)

  defp format_hazards(hazards),
    do: Enum.map_join(hazard_keys(), ", ", fn key -> "#{key}=#{Map.fetch!(hazards, key)}" end)

  defp invalid_hazard_snapshot!,
    do:
      raise(
        "communication rollback compatibility check failed: " <>
          "PostgreSQL returned an invalid hazard snapshot"
      )

  defp load_app do
    Application.load(@app)
  end

  defp migration_error(:one_shot_runtime_required), do: "one_shot_runtime_required"

  defp migration_error(:rollback_target_revision_required),
    do: "K_COMMS_ROLLBACK_TARGET_REVISION must contain a safe target revision identifier"

  defp migration_error(:rollback_writes_quiescence_confirmation_required),
    do: "K_COMMS_ROLLBACK_WRITES_QUIESCED must be true for a guest-incompatible target"
end
