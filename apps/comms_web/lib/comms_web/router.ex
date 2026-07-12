defmodule CommsWeb.Router do
  use CommsWeb, :router
  pipeline :api do
    plug :accepts, ["json"]
  end
  scope "/", CommsWeb do
    pipe_through :api
    get "/health/live", HealthController, :live
    get "/health/ready", HealthController, :ready
  end
  scope "/api/v1", CommsWeb do
    pipe_through :api
    get "/status", StatusController, :show
  end
end
