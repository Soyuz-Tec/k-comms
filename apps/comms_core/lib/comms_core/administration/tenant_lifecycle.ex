defmodule CommsCore.Administration.TenantLifecycle do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Administration.{Projector, Tenant, TenantView}
  alias CommsCore.Repo

  def append_bootstrap_tenant(multi, operation, attrs)
      when is_atom(operation) and is_map(attrs) do
    Ecto.Multi.run(multi, operation, fn repo, _changes ->
      persist_bootstrap_tenant(repo, attrs)
    end)
  end

  def create_bootstrap_tenant(attrs) when is_map(attrs) do
    if Repo.in_transaction?(),
      do: persist_bootstrap_tenant(Repo, attrs),
      else: {:error, :transaction_required}
  end

  def get_bootstrap_tenant_by_slug(slug) when is_binary(slug) do
    Tenant
    |> Repo.get_by(slug: slug)
    |> case do
      %Tenant{} = tenant -> Projector.tenant(tenant)
      nil -> nil
    end
  end

  def any_tenant?, do: Repo.exists?(Tenant)

  def release_tenant_fingerprint_id(repo, tenant_slug)
      when is_atom(repo) and is_binary(tenant_slug) do
    repo.one(
      from(tenant in Tenant,
        where: tenant.slug == ^tenant_slug,
        select: tenant.id
      )
    )
  end

  def delete_release_qualification_tenant(%TenantView{} = expected) do
    if Repo.in_transaction?() do
      tenant =
        Repo.one(
          from(t in Tenant,
            where:
              t.id == ^expected.id and t.slug == ^expected.slug and
                t.name == ^expected.name,
            lock: "FOR UPDATE"
          )
        )

      case tenant do
        %Tenant{} = value ->
          case Repo.delete(value) do
            {:ok, deleted} -> {:ok, Projector.tenant(deleted)}
            {:error, reason} -> {:error, reason}
          end

        nil ->
          {:error, :qualification_tenant_identity_conflict}
      end
    else
      {:error, :transaction_required}
    end
  end

  def delete_release_qualification_tenant(_expected),
    do: {:error, :qualification_tenant_identity_conflict}

  def active_tenant(tenant_id) when is_binary(tenant_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(tenant_id),
         %Tenant{} = tenant <- Repo.get_by(Tenant, id: tenant_id, status: :active) do
      {:ok, Projector.tenant(tenant)}
    else
      _ -> {:error, :tenant_unavailable}
    end
  end

  def active_tenant(_tenant_id), do: {:error, :tenant_unavailable}

  def active_tenant_by_slug(slug) when is_binary(slug) do
    case Repo.get_by(Tenant, slug: slug, status: :active) do
      %Tenant{} = tenant -> {:ok, Projector.tenant(tenant)}
      nil -> {:error, :tenant_unavailable}
    end
  end

  def active_tenant_by_slug(_slug), do: {:error, :tenant_unavailable}

  defp persist_bootstrap_tenant(repo, attrs) do
    %Tenant{id: value(attrs, :id)}
    |> Tenant.changeset(%{
      name: value(attrs, :name),
      slug: value(attrs, :slug),
      status: :active
    })
    |> repo.insert()
    |> case do
      {:ok, tenant} -> {:ok, Projector.tenant(tenant)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
