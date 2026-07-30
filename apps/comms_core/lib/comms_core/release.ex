defmodule CommsCore.Release do
  @moduledoc """
  Stable release-console facade.

  Deployment manifests and operational automation invoke this module directly.
  Responsibility-specific implementations live under `CommsCore.Release`.
  """

  alias CommsCore.Repo
  alias CommsCore.Attachments.{RestoreCandidate, RestoredObjectIdentity}

  alias CommsCore.Release.{
    AttachmentRestore,
    Environment,
    InstantRoomFingerprint,
    Migration,
    PlatformRoles,
    RollbackCompatibility,
    TenantOperations
  }

  defdelegate migrate(), to: Migration

  @doc """
  Refuses release-driven schema down-migrations.

  Application rollback restores a previously qualified image only after its
  compatibility preflight. Database recovery uses a verified backup or an
  explicitly reviewed forward repair; a down migration cannot reconstruct
  deleted or transformed business data.
  """
  @spec rollback(module(), integer()) :: no_return()
  defdelegate rollback(repo, version), to: Migration

  @doc """
  Refuses activation of a guest-incompatible rollback target while guest state
  or runnable guest-expiry work remains.
  """
  @spec assert_guest_rollback_compatible!() :: :ok
  defdelegate assert_guest_rollback_compatible!(), to: RollbackCompatibility

  @doc false
  def assert_guest_rollback_compatible, do: assert_guest_rollback_compatible!()

  @doc """
  Refuses activation of a communication-incompatible rollback target while
  persisted communication state requires capabilities the target lacks.
  """
  @spec assert_communication_rollback_compatible!() :: :ok
  defdelegate assert_communication_rollback_compatible!(), to: RollbackCompatibility

  @doc false
  def assert_communication_rollback_compatible,
    do: assert_communication_rollback_compatible!()

  defdelegate bootstrap(), to: TenantOperations
  defdelegate qualification_tenant(), to: TenantOperations

  @doc """
  Prints a content-free fingerprint of the configured fixed instant-room tenant.
  """
  @spec instant_room_tenant_fingerprint() :: :ok
  defdelegate instant_room_tenant_fingerprint(), to: InstantRoomFingerprint, as: :run

  @doc """
  Verifies restored attachment objects and atomically remaps their version IDs.
  """
  @spec remap_restored_attachment_versions((RestoreCandidate.t() ->
                                              {:ok, RestoredObjectIdentity.t()} | {:error, term()})) ::
          :ok
  def remap_restored_attachment_versions(verifier),
    do: AttachmentRestore.remap_restored_attachment_versions(verifier)

  @doc false
  defdelegate validate_restore_remap_environment(get_env),
    to: Environment,
    as: :validate_restore_remap

  @doc false
  defdelegate validate_migration_environment(get_env), to: Environment, as: :validate_migration

  @doc false
  defdelegate validate_qualification_environment(get_env),
    to: Environment,
    as: :validate_qualification

  @doc false
  defdelegate validate_instant_room_fingerprint_environment(get_env),
    to: Environment,
    as: :validate_instant_room_fingerprint

  @doc false
  defdelegate instant_room_tenant_fingerprint_categories(),
    to: InstantRoomFingerprint,
    as: :categories

  @doc false
  defdelegate instant_room_tenant_fingerprint(repo, tenant_slug),
    to: InstantRoomFingerprint,
    as: :fingerprint

  @doc false
  defdelegate format_instant_room_tenant_fingerprint(report),
    to: InstantRoomFingerprint,
    as: :format

  @doc false
  defdelegate validate_guest_rollback_environment(get_env),
    to: Environment,
    as: :validate_guest_rollback

  @doc false
  defdelegate validate_communication_rollback_environment(get_env),
    to: Environment,
    as: :validate_communication_rollback

  @doc false
  defdelegate assert_migration_preflight!(repo, settings), to: Migration

  @doc false
  defdelegate assert_migration_preflight_result!(rows, settings), to: Migration

  @doc false
  def assert_database_quiesced!(repo \\ Repo),
    do: Migration.assert_database_quiesced!(repo)

  @doc false
  defdelegate assert_database_quiescence_result!(rows), to: Migration

  @doc false
  defdelegate assert_guest_rollback_hazards!(rows, capabilities), to: RollbackCompatibility

  @doc false
  defdelegate assert_communication_rollback_hazards!(rows, capabilities),
    to: RollbackCompatibility

  @doc """
  Grants or revokes a platform role through the release console boundary.
  """
  defdelegate set_platform_role(user_id, role), to: PlatformRoles

  defdelegate set_platform_role(user_id, role, grant_token, actor, reason), to: PlatformRoles

  defdelegate set_platform_role(user_id, role, grant_token, actor, reason, ttl_seconds),
    to: PlatformRoles
end
