defmodule CommsWeb.Router do
  use CommsWeb, :router

  @instant_room_creation_rate_limits_enabled Application.compile_env(
                                               :comms_web,
                                               :instant_room_creation_rate_limits_enabled,
                                               true
                                             )

  pipeline :api do
    plug(:accepts, ["json"])
    plug(CommsWeb.Plugs.RateLimit, limit: 120, window: 60, scope: :ip)
  end

  pipeline :authenticated_api do
    plug(:accepts, ["json"])
    plug(CommsWeb.Plugs.Authenticate)
    plug(CommsWeb.Plugs.RateLimit, limit: 600, window: 60, scope: :identity)
  end

  pipeline :authenticated_export_api do
    plug(:accepts, ["csv", "json"])
    plug(CommsWeb.Plugs.Authenticate)
    plug(CommsWeb.Plugs.RateLimit, limit: 600, window: 60, scope: :identity)
  end

  pipeline :authentication_api do
    plug(:accepts, ["json"])
    plug(CommsWeb.Plugs.RequireSecureTransport)
    plug(CommsWeb.Plugs.RateLimit, limit: 60, window: 60, scope: :authentication_ip)
    plug(CommsWeb.Plugs.RateLimit, limit: 20, window: 60, scope: :authentication)
  end

  pipeline :guest_admission_api do
    plug(:accepts, ["json"])
    plug(CommsWeb.Plugs.RateLimit, limit: 30, window: 60, scope: :guest_admission_ip)
    plug(CommsWeb.Plugs.RateLimit, limit: 10, window: 60, scope: :guest_admission_token)
  end

  pipeline :instant_room_create_api do
    plug(:accepts, ["json"])
    plug(CommsWeb.Plugs.RequireSameOriginJSON)
    plug(CommsWeb.Plugs.OptionalHumanAuthentication)

    if @instant_room_creation_rate_limits_enabled do
      plug(CommsWeb.Plugs.RateLimit, limit: 20, window: 60, scope: :ip)

      plug(CommsWeb.Plugs.DistributedRateLimit,
        scope: :instant_room_create,
        limit: 2,
        window: 60
      )
    end
  end

  pipeline :instant_room_join_api do
    plug(:accepts, ["json"])
    plug(CommsWeb.Plugs.RequireSameOriginJSON)
    plug(CommsWeb.Plugs.RateLimit, limit: 60, window: 60, scope: :ip)
    plug(CommsWeb.Plugs.OptionalHumanAuthentication)

    plug(CommsWeb.Plugs.DistributedRateLimit,
      scope: :instant_room_join,
      limit: 10,
      window: 60
    )
  end

  pipeline :guest_api do
    plug(:accepts, ["json"])
    plug(CommsWeb.Plugs.AuthenticateGuest)
    plug(CommsWeb.Plugs.RateLimit, limit: 300, window: 60, scope: :identity)
  end

  pipeline :guest_account_conversion_api do
    plug(:accepts, ["json"])
    plug(CommsWeb.Plugs.RequireSecureTransport)

    plug(CommsWeb.Plugs.RateLimit,
      limit: 5,
      window: 60,
      scope: :guest_account_conversion_ip
    )

    plug(CommsWeb.Plugs.AuthenticateGuest)

    plug(CommsWeb.Plugs.RateLimit,
      limit: 5,
      window: 60,
      scope: :guest_account_conversion_identity
    )

    plug(CommsWeb.Plugs.DistributedRateLimit,
      scope: :instant_room_conversion,
      limit: 5,
      window: 60
    )

    plug(CommsWeb.Plugs.DistributedRateLimit,
      scope: :instant_room_conversion,
      limit: 5,
      window: 60,
      key_source: :authenticated_subject
    )
  end

  pipeline :service_api do
    plug(:accepts, ["json"])
    plug(CommsWeb.Plugs.RateLimit, limit: 600, window: 60, scope: :service_authentication_ip)
    plug(CommsWeb.Plugs.AuthenticateService)
    plug(CommsWeb.Plugs.RateLimit, limit: 600, window: 60, scope: :identity)
  end

  pipeline :scim_api do
    plug(:accepts, ["json", "scim"])
    plug(CommsWeb.Plugs.RequireSecureTransport)
    plug(CommsWeb.Plugs.RateLimit, limit: 600, window: 60, scope: :service_authentication_ip)
    plug(CommsWeb.Plugs.AuthenticateService)
    plug(CommsWeb.Plugs.RateLimit, limit: 600, window: 60, scope: :identity)
  end

  pipeline :password_verification_api do
    plug(:accepts, ["json"])
    plug(CommsWeb.Plugs.RequireSecureTransport)
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

  pipeline :telephony_provider_api do
    plug(:accepts, ["json"])
    plug(CommsWeb.Plugs.RequireSecureTransport)
    plug(CommsWeb.Plugs.RateLimit, limit: 600, window: 60, scope: :telephony_provider_ip)
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

  scope "/api/v1/telephony", CommsWeb do
    pipe_through(:telephony_provider_api)
    post("/livekit/webhook", TelephonyWebhookController, :create)
    post("/pbx/webhook", TelephonyPBXWebhookController, :create)
  end

  scope "/api/v1/providers", CommsWeb do
    pipe_through(:telephony_provider_api)
    post("/livekit/egress/webhook", CallArtifactWebhookController, :create)
  end

  scope "/api/v1", CommsWeb do
    pipe_through(:authentication_api)
    post("/bootstrap", BootstrapController, :create)
    post("/sessions", SessionController, :create)
    post("/sessions/refresh", SessionController, :refresh)
    post("/auth/mfa", EnterpriseIdentityController, :complete_mfa)
    post("/auth/oidc/start", EnterpriseIdentityController, :oidc_start)
    post("/auth/oidc/callback", EnterpriseIdentityController, :oidc_callback)
    post("/invitations/accept", InvitationController, :accept)
    post("/password-recovery/requests", PasswordRecoveryController, :request)
    post("/password-recovery/resets", PasswordRecoveryController, :reset)
  end

  scope "/api/v1", CommsWeb do
    pipe_through(:guest_admission_api)
    post("/guest-links/preview", GuestSessionController, :preview)
    post("/guest-sessions", GuestSessionController, :create)
    post("/guest/sessions/refresh", GuestSessionController, :refresh)
  end

  scope "/api/v1", CommsWeb do
    pipe_through(:instant_room_create_api)
    post("/instant-rooms", InstantRoomController, :create)
  end

  scope "/api/v1", CommsWeb do
    pipe_through(:instant_room_join_api)
    post("/instant-rooms/preview", InstantRoomController, :preview)
    post("/instant-room-sessions", InstantRoomController, :join)
  end

  scope "/api/v1/guest", CommsWeb do
    pipe_through(:guest_api)

    get("/conversation", GuestCommunicationController, :show_conversation)
    get("/conversation/members", GuestCommunicationController, :members)
    get("/conversation/messages", GuestCommunicationController, :messages)
    post("/conversation/message-sender-labels", GuestCommunicationController, :sender_labels)
    post("/conversation/messages", GuestCommunicationController, :create_message)
    put("/conversation/read-cursor", GuestCommunicationController, :update_read_cursor)

    get(
      "/conversation/whiteboard/operations",
      GuestCommunicationController,
      :whiteboard_operations
    )

    post(
      "/conversation/whiteboard/operations",
      GuestCommunicationController,
      :create_whiteboard_operation
    )

    post("/socket-tickets", GuestCommunicationController, :socket_ticket)
    get("/conversation/call", GuestCommunicationController, :show_call)
    get("/conversation/calls/:call_id/artifacts", GuestCallArtifactController, :index)

    post(
      "/conversation/calls/:call_id/artifacts/:id/consent",
      GuestCallArtifactController,
      :consent
    )

    post("/conversation/calls", GuestCommunicationController, :create_call)
    post("/conversation/calls/:call_id/join", GuestCommunicationController, :join_call)
    post("/conversation/calls/:call_id/end", GuestCommunicationController, :end_call)
    delete("/sessions/current", GuestSessionController, :delete)
  end

  scope "/api/v1/guest", CommsWeb do
    pipe_through(:guest_account_conversion_api)
    post("/account", GuestSessionController, :convert_account)
  end

  scope "/api/v1", CommsWeb do
    pipe_through(:authenticated_api)

    get("/whiteboards", WhiteboardLibraryController, :index)
    put("/conversations/:conversation_id/whiteboard/title", WhiteboardLibraryController, :rename)

    get(
      "/conversations/:conversation_id/whiteboard/versions",
      WhiteboardLibraryController,
      :versions
    )

    post(
      "/conversations/:conversation_id/whiteboard/versions",
      WhiteboardLibraryController,
      :checkpoint
    )

    post(
      "/conversations/:conversation_id/whiteboard/versions/:version_id/restore",
      WhiteboardLibraryController,
      :restore
    )

    get("/conversations/:conversation_id/whiteboard/export", WhiteboardLibraryController, :export)
    get("/conversations/:conversation_id/documents", SharedDocumentController, :index)
    post("/conversations/:conversation_id/documents", SharedDocumentController, :create)
    get("/documents/:document_id", SharedDocumentController, :show)
    post("/documents/:document_id/copies", SharedDocumentController, :copy)
    post("/documents/:document_id/operations", SharedDocumentController, :operation)
    get("/documents/:document_id/operations", SharedDocumentController, :replay)
    get("/documents/:document_id/export", SharedDocumentController, :export)

    post(
      "/conversations/:conversation_id/whiteboard/assets",
      WhiteboardLibraryController,
      :create_asset
    )

    get(
      "/conversations/:conversation_id/whiteboard/assets/:asset_id",
      WhiteboardLibraryController,
      :asset
    )

    get("/saved-items", PersonalContentController, :saved)
    put("/saved-items/:message_id", PersonalContentController, :save)
    delete("/saved-items/:message_id", PersonalContentController, :unsave)
    get("/conversations/:conversation_id/draft", PersonalContentController, :draft)
    put("/conversations/:conversation_id/draft", PersonalContentController, :update_draft)
    get("/search/unified", UnifiedSearchController, :index)

    get("/me/security", EnterpriseIdentityController, :security)
    post("/me/mfa/enroll", EnterpriseIdentityController, :enroll_mfa)
    post("/me/mfa/confirm", EnterpriseIdentityController, :confirm_mfa)
    post("/me/mfa/disable", EnterpriseIdentityController, :disable_mfa)
    post("/me/mfa/recovery-codes", EnterpriseIdentityController, :recovery_codes)
    get("/me/availability", EnterpriseIdentityController, :availability)
    put("/me/availability", EnterpriseIdentityController, :update_availability)
    post("/me/oidc/step-up/start", EnterpriseIdentityController, :oidc_step_up)
    post("/me/oidc/link/start", EnterpriseIdentityController, :oidc_link)
    post("/me/oidc/link/callback", EnterpriseIdentityController, :oidc_link_callback)

    get("/meetings", MeetingController, :index)
    post("/conversations/:conversation_id/meetings", MeetingController, :create)
    get("/meetings/:meeting_id", MeetingController, :show)
    patch("/meetings/:meeting_id", MeetingController, :update)
    post("/meetings/:meeting_id/cancel", MeetingController, :cancel)
    get("/meetings/:meeting_id/calendar", MeetingController, :calendar)
    post("/meetings/:meeting_id/occurrences/:occurrence_id/start", MeetingController, :start)

    get("/me", MeController, :show)
    get("/telephony/voicemails", VoicemailController, :index)
    get("/telephony/voicemails/:id/playback", VoicemailController, :playback)
    post("/telephony/voicemails/:id/read", VoicemailController, :read)
    delete("/telephony/voicemails/:id", VoicemailController, :delete)
    get("/admin/telephony/mailbox", VoicemailController, :mailbox)
    put("/admin/telephony/mailbox", VoicemailController, :save_mailbox)
    get("/admin/telephony/routes", TelephonyController, :routes)
    put("/admin/telephony/routes", TelephonyController, :save_route)
    get("/telephony/capabilities", TelephonyController, :capabilities)
    get("/telephony/calls/:id/controls", TelephonyController, :controls)
    post("/telephony/calls/:id/controls", TelephonyController, :control)

    post(
      "/telephony/calls/:id/controls/:command_id/complete",
      TelephonyController,
      :complete_control
    )

    post(
      "/telephony/calls/:id/controls/:command_id/reconcile",
      TelephonyController,
      :reconcile_control
    )

    get(
      "/conversations/:conversation_id/calls/:call_id/artifacts",
      CallArtifactController,
      :index
    )

    post(
      "/conversations/:conversation_id/calls/:call_id/artifacts",
      CallArtifactController,
      :create
    )

    post(
      "/conversations/:conversation_id/calls/:call_id/artifacts/:id/consent",
      CallArtifactController,
      :consent
    )

    post(
      "/conversations/:conversation_id/calls/:call_id/artifacts/:id/start",
      CallArtifactController,
      :start
    )

    post(
      "/conversations/:conversation_id/calls/:call_id/artifacts/:id/stop",
      CallArtifactController,
      :stop
    )

    get(
      "/conversations/:conversation_id/calls/:call_id/artifacts/:id/playback",
      CallArtifactController,
      :playback
    )

    get(
      "/conversations/:conversation_id/calls/:call_id/artifacts/:id/transcript",
      CallArtifactController,
      :transcript
    )

    delete(
      "/conversations/:conversation_id/calls/:call_id/artifacts/:id",
      CallArtifactController,
      :delete
    )

    get("/me/workspace", MemberWorkspaceController, :show)
    put("/me/workspace", MemberWorkspaceController, :update)
    patch("/me/onboarding", MemberWorkspaceController, :onboarding)
    get("/telephony/config", TelephonyController, :config)
    get("/telephony/calls", TelephonyController, :index)
    get("/telephony/calls/:id", TelephonyController, :show)
    post("/telephony/calls", TelephonyController, :create)
    post("/telephony/calls/:id/answer", TelephonyController, :answer)
    post("/telephony/calls/:id/reject", TelephonyController, :reject)
    post("/telephony/calls/:id/end", TelephonyController, :end_call)
    post("/telephony/calls/:id/join", TelephonyController, :join)
    get("/admin/telephony", TelephonyController, :admin_config)
    put("/admin/telephony", TelephonyController, :provision)
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
    get("/directory/users", DirectoryController, :index)
    delete("/sessions/current", SessionController, :delete)

    get("/channels/discover", ConversationController, :discover_public)
    post("/channels/:id/join", ConversationController, :join_public)
    delete("/channels/:id/membership", ConversationController, :leave_public)
    post("/direct-conversations", ConversationController, :create_direct)

    resources "/conversations", ConversationController, only: [:index, :create, :show, :update] do
      post("/archive", ConversationController, :archive)
      get("/guest-links", GuestLinkController, :index)
      post("/guest-links", GuestLinkController, :create)
      delete("/guest-links/:link_id", GuestLinkController, :revoke)
      get("/call", AudioCallController, :show)
      post("/calls", AudioCallController, :create)
      post("/calls/:call_id/join", AudioCallController, :join)
      post("/calls/:call_id/end", AudioCallController, :end_call)
      get("/calls/:call_id/participants", AudioCallController, :participants)
      post("/calls/:call_id/participants/mute", AudioCallController, :mute_participant)
      post("/calls/:call_id/participants/remove", AudioCallController, :remove_participant)
      get("/audio-call", AudioCallController, :show_audio)
      post("/audio-calls", AudioCallController, :create_audio)
      post("/audio-calls/:call_id/join", AudioCallController, :join_audio)
      post("/audio-calls/:call_id/end", AudioCallController, :end_audio)
      get("/members", ConversationController, :members)
      post("/members", ConversationController, :add_member)
      patch("/members/:user_id", ConversationController, :update_member)
      delete("/members/:user_id", ConversationController, :remove_member)
      get("/messages", MessageController, :index)
      get("/activity", ConversationActivityController, :index)
      post("/message-sender-labels", MessageController, :sender_labels)
      post("/messages", MessageController, :create)
      get("/whiteboard/operations", WhiteboardController, :index)
      post("/whiteboard/operations", WhiteboardController, :create)
      get("/messages/:message_id/thread", MessageController, :thread)
      put("/read-cursor", ReadCursorController, :update)
      get("/delivery-cursors", MessageDeliveryController, :index)
      put("/delivery-cursor", MessageDeliveryController, :update)
      post("/messages/:message_id/reactions", ReactionController, :create)
      delete("/messages/:message_id/reactions/:emoji", ReactionController, :delete)
    end

    patch("/messages/:id", MessageController, :update)
    delete("/messages/:id", MessageController, :delete)
    get("/search", SearchController, :index)

    post("/attachments", AttachmentController, :create)
    get("/files", AttachmentController, :index)
    post("/attachments/:id/complete", AttachmentController, :complete)
    get("/attachments/:id", AttachmentController, :show)
    delete("/attachments/:id", AttachmentController, :delete)
    get("/calls", AudioCallController, :index)

    get("/moderation/cases", ModerationController, :index)
    post("/moderation/cases", ModerationController, :create)
    get("/moderation/cases/:id", ModerationController, :show)
    post("/moderation/cases/:case_id/actions", ModerationController, :add_action)

    get("/admin/tenant", AdminTenantController, :show)
    patch("/admin/tenant", AdminTenantController, :update)
    get("/admin/usage", UsageReportController, :index)
    get("/admin/role-permissions", RolePermissionController, :index)
    post("/admin/users/:id/role-preview", RolePermissionController, :preview)
    get("/admin/users", AdminUserController, :index)
    patch("/admin/users/:id", AdminUserController, :update)
    get("/admin/users/:user_id/sessions", AdminUserController, :sessions)
    delete("/admin/users/:user_id/sessions/:id", AdminUserController, :revoke_session)
    get("/admin/invitations", InvitationController, :index)
    post("/admin/invitations", InvitationController, :create)
    post("/admin/invitations/:id/revoke", InvitationController, :revoke)
    get("/admin/audit-events", AuditController, :index)
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
    get("/admin/deletion-requests/:id/timeline", DeletionRequestHistoryController, :index)

    get("/ops", OpsController, :show)
    post("/ops/retry", OpsController, :retry)
    get("/platform/ops", OpsController, :platform)
  end

  scope "/api/v1", CommsWeb do
    pipe_through(:authenticated_export_api)

    get("/admin/usage/export", UsageReportController, :export)
    post("/admin/audit-events/export", AuditExportController, :create)
    get("/admin/deletion-requests/:id/timeline/export", DeletionRequestHistoryController, :export)
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

  scope "/scim/v2", CommsWeb do
    pipe_through(:scim_api)
    get("/ServiceProviderConfig", ScimController, :configuration)
    get("/Users", ScimController, :users)
    post("/Users", ScimController, :create_user)
    get("/Users/:id", ScimController, :user)
    put("/Users/:id", ScimController, :replace_user)
    patch("/Users/:id", ScimController, :patch_user)
    delete("/Users/:id", ScimController, :delete_user)
    get("/Groups", ScimController, :groups)
    post("/Groups", ScimController, :create_group)
    get("/Groups/:id", ScimController, :group)
    put("/Groups/:id", ScimController, :replace_group)
    patch("/Groups/:id", ScimController, :patch_group)
    delete("/Groups/:id", ScimController, :delete_group)
  end

  scope "/", CommsWeb do
    get("/app", SpaController, :canonical_app)
    get("/*path", SpaController, :index)
  end
end
