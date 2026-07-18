defmodule CommsCore.Administration.AuthorizationActorPort do
  @moduledoc """
  TenantAdministration-owned port for verified authorization-denial identity.

  IdentityAccess implements this bounded read at the composition root. The
  returned DTO contains attribution only and exposes no identity persistence.
  """

  alias CommsCore.Administration.AuthorizationActor

  @callback resolve_authorization_actor(map()) ::
              {:ok, AuthorizationActor.t()} | {:error, :unknown_authorization_actor}

  @spec resolve_authorization_actor(map()) ::
          {:ok, AuthorizationActor.t()} | {:error, :unknown_authorization_actor}
  def resolve_authorization_actor(subject) when is_map(subject) do
    :resolve_authorization_actor
    |> dispatch([subject])
    |> validate_actor(subject)
  end

  def resolve_authorization_actor(_subject),
    do: {:error, :unknown_authorization_actor}

  defp dispatch(operation, args) do
    with {:ok, adapter} <-
           Application.fetch_env(:comms_core, :tenant_authorization_actor_adapter),
         true <- is_atom(adapter) and Code.ensure_loaded?(adapter),
         true <- function_exported?(adapter, operation, length(args)) do
      apply(adapter, operation, args)
    else
      _ -> {:error, :unknown_authorization_actor}
    end
  end

  defp validate_actor({:ok, %AuthorizationActor{} = actor}, subject) do
    if valid_uuid?(actor.tenant_id) and valid_uuid?(actor.user_id) and
         actor.tenant_id == value(subject, :tenant_id) and
         actor.user_id == value(subject, :user_id) and
         actor.request_id == value(subject, :request_id) do
      {:ok, actor}
    else
      {:error, :unknown_authorization_actor}
    end
  end

  defp validate_actor({:error, :unknown_authorization_actor} = error, _subject),
    do: error

  defp validate_actor(_result, _subject),
    do: {:error, :unknown_authorization_actor}

  defp valid_uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, found} -> found
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
