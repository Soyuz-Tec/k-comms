defmodule CommsWeb.Application do
  use Application
  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: CommsWeb.PubSub},
      CommsWeb.Presence,
      CommsWeb.Endpoint
    ]
    Supervisor.start_link(children, strategy: :one_for_one, name: CommsWeb.Supervisor)
  end
  @impl true
  def config_change(changed, _new, removed), do: CommsWeb.Endpoint.config_change(changed, removed)
end
