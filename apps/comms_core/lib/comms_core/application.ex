defmodule CommsCore.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [CommsCore.Repo, {Oban, Application.fetch_env!(:comms_core, Oban)}]
    Supervisor.start_link(children, strategy: :one_for_one, name: CommsCore.Supervisor)
  end
end
