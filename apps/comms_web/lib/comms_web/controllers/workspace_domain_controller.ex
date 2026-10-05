defmodule CommsWeb.WorkspaceDomainController do
  use CommsWeb, :controller
  alias CommsCore.Administration
  alias CommsCore.Administration.DomainClaimView

  def index(conn, _params) do
    with {:ok, claims} <- Administration.list_workspace_domains(conn.assigns.current_subject) do
      json(conn, %{data: Enum.map(claims, &present/1), limits: %{domains: 8}})
    end
  end

  def create(conn, params) do
    with {:ok, claim} <-
           Administration.create_workspace_domain(params, conn.assigns.current_subject) do
      conn |> put_status(:created) |> json(%{data: present(claim)})
    end
  end

  def renew(conn, %{"id" => id} = params) do
    with {:ok, claim} <-
           Administration.renew_workspace_domain(id, params, conn.assigns.current_subject) do
      json(conn, %{data: present(claim)})
    end
  end

  def verify(conn, %{"id" => id} = params) do
    with {:ok, claim} <-
           Administration.verify_workspace_domain(id, params, conn.assigns.current_subject) do
      json(conn, %{data: present(claim)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, claim} <-
           Administration.update_workspace_domain_discovery(
             id,
             params,
             conn.assigns.current_subject
           ) do
      json(conn, %{data: present(claim)})
    end
  end

  def revoke(conn, %{"id" => id} = params) do
    with {:ok, claim} <-
           Administration.revoke_workspace_domain(id, params, conn.assigns.current_subject) do
      json(conn, %{data: present(claim)})
    end
  end

  defp present(%DomainClaimView{} = claim) do
    claim
    |> Map.from_struct()
    |> Map.update!(:status, &Atom.to_string/1)
    |> Map.update!(:challenge_expires_at, &DateTime.to_iso8601/1)
    |> Map.update!(:verified_at, &timestamp/1)
    |> Map.update!(:proof_expires_at, &timestamp/1)
  end

  defp timestamp(nil), do: nil
  defp timestamp(value), do: DateTime.to_iso8601(value)
end
