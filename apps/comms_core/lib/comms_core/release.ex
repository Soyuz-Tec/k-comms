defmodule CommsCore.Release do
  @app :comms_core

  alias CommsCore.{Accounts, Attachments, Repo}
  alias CommsCore.Attachments.{RestoreCandidate, RestoreContext, RestoredObjectIdentity}

  @restore_remap_confirmation "remap-restored-attachment-versions"

  def migrate do
    load_app()

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          Ecto.Migrator.run(repo, :up, all: true)
        end)
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

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
end
