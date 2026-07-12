defmodule CommsWeb.StatusController do
  use CommsWeb, :controller
  def show(conn, _params), do: json(conn, %{service: "k-comms", version: to_string(Application.spec(:comms_web, :vsn)), status: "bootstrap"})
end
