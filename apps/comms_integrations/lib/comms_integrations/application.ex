defmodule CommsIntegrations.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Finch, name: CommsIntegrations.Finch},
      {Task.Supervisor, name: CommsIntegrations.TaskSupervisor},
      CommsIntegrations.Audio.LiveKitReadiness
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: CommsIntegrations.Supervisor
    )
  end
end
