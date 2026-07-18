defmodule CommsCore.Authorization.Policy do
  @moduledoc """
  Stable authorization policy contract used by the public dispatcher.
  """

  @callback authorize(atom(), map(), struct() | map()) :: :ok | {:error, term()}

  @spec authorize(module(), atom(), map(), struct() | map()) :: :ok | {:error, term()}
  def authorize(adapter, action, subject, resource) when is_atom(adapter) do
    adapter.authorize(action, subject, resource)
  end
end
