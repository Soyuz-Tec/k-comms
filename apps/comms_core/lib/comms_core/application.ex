defmodule CommsCore.Application do
  use Application

  @impl true
  def start(_type, _args) do
    topologies = Application.get_env(:comms_core, :cluster_topologies, [])

    children = [
      {Cluster.Supervisor, [topologies, [name: CommsCore.ClusterSupervisor]]},
      CommsCore.Repo,
      {Oban, Application.fetch_env!(:comms_core, Oban)}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: CommsCore.Supervisor)
  end
end
