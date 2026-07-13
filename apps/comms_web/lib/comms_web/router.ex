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
    plug(CommsWeb.Plugs.RateLimit, limit: 60, window: 60, scope: :authentication_ip)
    plug(CommsWeb.Plugs.RateLimit, limit: 20, window: 60, scope: :authentication)
  end

  pipeline :service_api do
    plug(:accepts, ["json"])
    plug(CommsWeb.Plugs.RateLimit, limit: 600, window: 60, scope: :service_authentication_ip)
    plug(CommsWeb.Plugs.AuthenticateService)
    plug(CommsWeb.Plugs.RateLimit, limit: 600, window: 60, scope: :identity)
  end

  pipeline :password_verification_api do
    plug(:accepts, ["json"])
    plug(CommsWeb.Plugs.RateLimit, limit: 20, window: 60, scope: :password_verification_ip)
    plug(CommsWeb.Plugs.Authenticate)

    plug(CommsWeb.Plugs.RateLimit,
      limit: 5,
      window: 60,
      scope: :password_verification_identity
    )
  end

  pipeline :metrics_api do
    plug(CommsWeb.Plugs.AuthenticateMetrics)
    plug(CommsWeb.Plugs.RateLimit, limit: 120, window: 60, scope: :ip)
  end

  scope "/", CommsWeb do
    pipe_through(:api)
    get("/health/live", HealthController, :live)
    get("/health/ready", HealthController, :ready)
  end

  scope "/", CommsWeb do
    pipe_through(:metrics_api)
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
    post("/invitations/accept", InvitationController, :accept)
    post("/password-recovery/requests", PasswordRecoveryController, :request)
    post("/password-recovery/resets", PasswordRecoveryController, :reset)
  end

  scope "/api/v1", CommsWeb do
    pipe_through(:authenticated_api)

    get("/me", MeController, :show)
    patch("/me/profile", ProfileController, :update)
    post("/socket-tickets", SocketTicketController, :create)
    get("/me/devices", ProfileController, :devices)
    delete("/me/devices/:id", ProfileController, :revoke_device)
    get("/me/sessions", ProfileController, :sessions)
    delete("/me/sessions/:id", ProfileController, :revoke_session)
    get("/notification-preferences", NotificationPreferenceController, :show)
    put("/notification-preferences", NotificationPreferenceController, :update)
    get("/notifications", NotificationController, :index)
    get("/notification-attempts", NotificationController, :attempts)
    post("/notification-intents/:id/retry", NotificationController, :retry)
    get("/me/push-subscriptions/config", PushSubscriptionController, :config)
    get("/me/push-subscriptions", PushSubscriptionController, :index)
    post("/me/push-subscriptions", PushSubscriptionController, :create)
    delete("/me/push-subscriptions/:id", PushSubscriptionController, :delete)
    get("/in-app-notifications", InAppNotificationController, :index)
    get("/in-app-notifications/unread-count", InAppNotificationController, :unread_count)
    post("/in-app-notifications/read-all", InAppNotificationController, :mark_all_read)
    patch("/in-app-notifications/:id/read", InAppNotificationController, :mark_read)
    delete("/in-app-notifications/:id", InAppNotificationController, :dismiss)
    get("/users", MeController, :users)
    delete("/sessions/current", SessionController, :delete)

    get("/channels/discover", ConversationController, :discover_public)
    post("/channels/:id/join", ConversationController, :join_public)
    delete("/channels/:id/membership", ConversationController, :leave_public)

    resources "/conversations", ConversationController, only: [:index, :create, :show, :update] do
      post("/archive", ConversationController, :archive)
      get("/members", ConversationController, :members)
      post("/members", ConversationController, :add_member)
      patch("/members/:user_id", ConversationController, :update_member)
      delete("/members/:user_id", ConversationController, :remove_member)
      get("/messages", MessageController, :index)
      post("/messages", MessageController, :create)
      get("/messages/:message_id/thread", MessageController, :thread)
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

    get("/moderation/cases", ModerationController, :index)
    post("/moderation/cases", ModerationController, :create)
    get("/moderation/cases/:id", ModerationController, :show)
    post("/moderation/cases/:case_id/actions", ModerationController, :add_action)

    get("/admin/tenant", AdminTenantController, :show)
    patch("/admin/tenant", AdminTenantController, :update)
    get("/admin/users", AdminUserController, :index)
    patch("/admin/users/:id", AdminUserController, :update)
    get("/admin/users/:user_id/sessions", AdminUserController, :sessions)
    delete("/admin/users/:user_id/sessions/:id", AdminUserController, :revoke_session)
    get("/admin/invitations", InvitationController, :index)
    post("/admin/invitations", InvitationController, :create)
    post("/admin/invitations/:id/revoke", InvitationController, :revoke)
    get("/admin/audit-events", AuditController, :index)
    post("/admin/audit-events/export", AuditExportController, :create)
    get("/admin/webhooks", WebhookEndpointController, :index)
    post("/admin/webhooks", WebhookEndpointController, :create)
    get("/admin/webhooks/:id", WebhookEndpointController, :show)
    patch("/admin/webhooks/:id", WebhookEndpointController, :update)
    delete("/admin/webhooks/:id", WebhookEndpointController, :delete)
    post("/admin/webhooks/:id/rotate-secret", WebhookEndpointController, :rotate_secret)
    get("/admin/webhook-deliveries", WebhookDeliveryController, :index)
    get("/admin/service-accounts", ServiceAccountController, :index)
    post("/admin/service-accounts", ServiceAccountController, :create)
    post("/admin/service-accounts/:id/rotate", ServiceAccountController, :rotate)
    post("/admin/service-accounts/:id/revoke", ServiceAccountController, :revoke)

    post(
      "/admin/webhook-deliveries/:id/replay",
      WebhookDeliveryController,
      :replay
    )

    get("/admin/attachment-safety", AttachmentSafetyController, :index)
    post("/admin/attachment-safety/:id/retry", AttachmentSafetyController, :retry)
    get("/admin/retention-policies", RetentionPolicyController, :index)
    post("/admin/retention-policies", RetentionPolicyController, :create)
    patch("/admin/retention-policies/:id", RetentionPolicyController, :update)
    get("/admin/legal-holds", LegalHoldController, :index)
    post("/admin/legal-holds", LegalHoldController, :create)
    post("/admin/legal-holds/:id/release", LegalHoldController, :release)
    get("/admin/deletion-requests", DeletionRequestController, :index)
    post("/admin/deletion-requests", DeletionRequestController, :create)
    patch("/admin/deletion-requests/:id", DeletionRequestController, :update)

    get("/ops", OpsController, :show)
    post("/ops/retry", OpsController, :retry)
    get("/platform/ops", OpsController, :platform)
  end

  scope "/api/v1", CommsWeb do
    pipe_through(:password_verification_api)

    put("/me/password", ProfileController, :password)
    post("/me/step-up", ProfileController, :step_up)
  end

  scope "/api/v1/service", CommsWeb do
    pipe_through(:service_api)

    get("/conversations", ServiceConversationController, :index)
    get("/conversations/:conversation_id/messages", ServiceMessageController, :index)
    post("/conversations/:conversation_id/messages", ServiceMessageController, :create)
    get("/search", ServiceSearchController, :index)
  end

  scope "/", CommsWeb do
    get("/*path", SpaController, :index)
  end
end
