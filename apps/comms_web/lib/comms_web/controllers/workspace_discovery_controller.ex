defmodule CommsWeb.WorkspaceDiscoveryController do
  use CommsWeb, :controller
  alias CommsCore.Administration

  def create(conn, params) do
    # Unknown, malformed, expired, opted-out and inactive domains use exactly
    # one public unavailable response. An email is never an accepted input.
    domain =
      if Map.keys(params) == ["domain"] and is_binary(params["domain"]),
        do: params["domain"],
        else: nil

    view = Administration.discover_workspace_domain(domain)
    json(conn, %{data: %{available: view.available, sign_in_path: view.sign_in_path}})
  end
end
