defmodule CommsCore.Release do
  @app :comms_core

  alias CommsCore.{Accounts, Repo}

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

  defp load_app do
    Application.load(@app)
  end

  defp bootstrap_error(:weak_password), do: "owner password does not meet policy"

  defp bootstrap_error(:bootstrap_identity_conflict),
    do: "a different or incomplete tenant bootstrap already exists"

  defp bootstrap_error(%Ecto.Changeset{}), do: "bootstrap attributes are invalid"
  defp bootstrap_error(_reason), do: "database operation failed"
end
