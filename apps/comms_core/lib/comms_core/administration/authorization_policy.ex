defmodule CommsCore.Administration.AuthorizationPolicy do
  @moduledoc false

  alias CommsCore.Administration.{
    AccessPolicy,
    AuthorizationActor,
    AuthorizationActorPort,
    IdentityAccessPort,
    IdentityGrant
  }

  alias CommsCore.Audit

  @spec authorize(AccessPolicy.permission(), map()) ::
          :ok | {:error, AccessPolicy.denial()}
  def authorize(permission, subject) when is_atom(permission) and is_map(subject) do
    permission
    |> decide(subject)
    |> audit_denial(permission, subject)
  end

  defp decide(permission, subject) do
    case IdentityAccessPort.resolve_access(subject) do
      {:ok, %IdentityGrant{} = grant} -> AccessPolicy.authorize(permission, grant)
      {:error, :forbidden} -> {:error, :forbidden}
    end
  end

  defp audit_denial(:ok, _permission, _subject), do: :ok

  defp audit_denial({:error, reason}, permission, subject) do
    case AuthorizationActorPort.resolve_authorization_actor(subject) do
      {:ok, %AuthorizationActor{} = actor} ->
        Audit.authorization_denied(
          permission,
          %CommsCore.Audit.Actor{
            tenant_id: actor.tenant_id,
            user_id: actor.user_id,
            request_id: actor.request_id
          },
          reason
        )

      {:error, :unknown_authorization_actor} ->
        {:error, reason}
    end
  end
end
