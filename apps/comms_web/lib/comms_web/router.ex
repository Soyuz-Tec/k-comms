defmodule CommsWeb.Router do
  use CommsWeb, :router

  pipeline :api do
    plug(:accepts, ["json"])
    plug(CommsWeb.Plugs.RateLimit, limit: 120, window: 60, scope: :ip)
  end

  pipeline :authenticated_api do
    plug(:accepts, ["json"])
    plug(CommsWeb.Plugs.Authenticate)
    plug(CommsWeb.Plugs.RateLimit, limit: 600, window: 60, scope: :identity)
  end

  pipeline :authentication_api do
    plug(:accepts, ["json"])
    plug(CommsWeb.Plugs.RateLimit, limit: 20, window: 60, scope: :authentication)
  end

  scope "/", CommsWeb do
    pipe_through(:api)
    get("/health/live", HealthController, :live)
    get("/health/ready", HealthController, :ready)
    get("/metrics", MetricsController, :show)
  end

  scope "/api/v1", CommsWeb do
    pipe_through(:api)
    get("/status", StatusController, :show)
  end

  scope "/api/v1", CommsWeb do
    pipe_through(:authentication_api)
    post("/bootstrap", BootstrapController, :create)
    post("/sessions", SessionController, :create)
    post("/sessions/refresh", SessionController, :refresh)
  end

  scope "/api/v1", CommsWeb do
    pipe_through(:authenticated_api)

    get("/me", MeController, :show)
    get("/users", MeController, :users)
    post("/users", UserController, :create)
    delete("/sessions/current", SessionController, :delete)

    resources "/conversations", ConversationController, only: [:index, :create, :show] do
      get("/members", ConversationController, :members)
      post("/members", ConversationController, :add_member)
      delete("/members/:user_id", ConversationController, :remove_member)
      get("/messages", MessageController, :index)
      post("/messages", MessageController, :create)
      put("/read-cursor", ReadCursorController, :update)
      post("/messages/:message_id/reactions", ReactionController, :create)
      delete("/messages/:message_id/reactions/:emoji", ReactionController, :delete)
    end

    patch("/messages/:id", MessageController, :update)
    delete("/messages/:id", MessageController, :delete)
    get("/search", SearchController, :index)

    post("/attachments", AttachmentController, :create)
    post("/attachments/:id/complete", AttachmentController, :complete)
    get("/attachments/:id", AttachmentController, :show)
  end

  scope "/", CommsWeb do
    get("/*path", SpaController, :index)
  end
end
