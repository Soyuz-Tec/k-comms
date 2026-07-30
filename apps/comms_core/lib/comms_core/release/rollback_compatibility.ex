defmodule CommsCore.Release.RollbackCompatibility do
  @moduledoc false

  alias CommsCore.{
    Accounts,
    Conversations,
    Repo,
    Release.Environment,
    Release.Migration,
    RuntimePorts
  }

  @app :comms_core

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

  defp load_app do
    Application.load(@app)
  end

  defp migration_error(:one_shot_runtime_required), do: "one_shot_runtime_required"

  defp migration_error(:rollback_target_revision_required),
    do: "K_COMMS_ROLLBACK_TARGET_REVISION must contain a safe target revision identifier"

  defp migration_error(:rollback_writes_quiescence_confirmation_required),
    do: "K_COMMS_ROLLBACK_WRITES_QUIESCED must be true for a guest-incompatible target"
end
