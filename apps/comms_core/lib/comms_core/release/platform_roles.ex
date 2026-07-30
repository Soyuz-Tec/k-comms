defmodule CommsCore.Release.PlatformRoles do
  @moduledoc false

  alias CommsCore.{Accounts, Repo}

  @app :comms_core

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
end
