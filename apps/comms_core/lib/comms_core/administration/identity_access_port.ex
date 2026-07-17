defmodule CommsCore.Administration.IdentityAccessPort do
  @moduledoc """
  TenantAdministration-owned read port for verified identity facts.

  IdentityAccess implements this contract at the composition root. These
  bounded reads are independent of a caller transaction; invitation mutations
  use the separate transaction-required invitation identity port.
  """

  alias CommsCore.Administration.IdentityGrant

  @roles [:owner, :admin, :moderator, :member, :compliance_admin, :security_admin]

  @callback resolve_access(map()) :: {:ok, IdentityGrant.t()} | {:error, :forbidden}

  @spec resolve_access(map()) :: {:ok, IdentityGrant.t()} | {:error, :forbidden}
  def resolve_access(subject) when is_map(subject) do
    :resolve_access
    |> dispatch([subject], :forbidden)
    |> validate_grant(subject)
  end

  def resolve_access(_subject), do: {:error, :forbidden}

  defp dispatch(operation, args, unavailable_reason) do
    with {:ok, adapter} <-
           Application.fetch_env(:comms_core, :tenant_identity_access_adapter),
         true <- is_atom(adapter) and Code.ensure_loaded?(adapter),
         true <- function_exported?(adapter, operation, length(args)) do
      apply(adapter, operation, args)
    else
      _ -> {:error, unavailable_reason}
    end
  end

  defp validate_grant({:ok, %IdentityGrant{} = grant}, subject) do
    if valid_uuid?(grant.tenant_id) and valid_uuid?(grant.user_id) and
         grant.tenant_id == value(subject, :tenant_id) and
         grant.user_id == value(subject, :user_id) and grant.role in @roles and
         is_boolean(grant.step_up_recent?) do
      {:ok, grant}
    else
      {:error, :forbidden}
    end
  end

  defp validate_grant({:error, :forbidden} = error, _subject), do: error
  defp validate_grant(_result, _subject), do: {:error, :forbidden}

  defp valid_uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, found} -> found
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
