defmodule CommsCore.Release.TenantOperations do
  @moduledoc false

  alias CommsCore.{Accounts, Release.Environment, Repo}

  @app :comms_core

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

  def qualification_tenant do
    with {:ok, context} <- Environment.validate_qualification(&System.get_env/1) do
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

  defp load_app do
    Application.load(@app)
  end

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
end
