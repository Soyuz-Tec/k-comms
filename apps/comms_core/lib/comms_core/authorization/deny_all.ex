defmodule CommsCore.Authorization.DenyAll do
  @behaviour CommsCore.Authorization.Policy

  @impl true
  def authorize(_action, _subject, _resource), do: {:error, :forbidden}
end
