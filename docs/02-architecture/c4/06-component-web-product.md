# C4 Level 3 — Web Product Components

```mermaid
flowchart LR
    Shell[Session and Route Shell]
    User[User Workspace]
    Admin[Tenant Administration]
    Ops[Platform Operations]
    API[Typed REST Client]
    Realtime[Realtime and Replay Client]
    Local[Draft and Offline State]
    PWA[PWA Install and Update Client]
    Worker[Install-scoped Service Worker\nPush + Static Offline Shell]
    Design[Accessible Design System]
    Media[Call Client\nConsent + Grid + Screen Share + LiveKit]

    Shell --> User
    Shell --> Admin
    Shell --> Ops
    User --> API
    User --> Realtime
    User --> Local
    Shell --> PWA
    PWA --> Worker
    User --> Media
    Media --> API
    Admin --> API
    Ops --> API
    User --> Design
    Admin --> Design
    Ops --> Design
```

## Rules

- The server-provided identity and permission set controls available routes and
  actions; hidden controls are not an authorization boundary.
- Durable messages and read state reconcile from server cursors after every
  reconnect. Local drafts and retries never become authoritative history.
- PWA installation is an explicit browser-mediated action. Service-worker
  registration never requests notification permission, and a waiting update
  activates only after the user chooses Reload.
- The `/app/` service worker may cache only the fixed offline document and
  revisioned same-origin static application assets. API, authentication,
  socket, message, file, attachment, invitation, call, media, and signed-URL
  traffic remains network-only; Cache Storage is not a conversation store or
  outbox.
- The user workspace may render authorized message content. Tenant-admin and
  operations queries return only the content required by their explicit policy.
- Shared API, error, loading, keyboard, focus, responsive, and accessibility
  behavior belongs in the shell/design platform rather than each feature.
- Camera, microphone, and screen capture begin only after explicit user
  actions. Camera and microphone default off in the video prejoin surface;
  screen sharing has a separate visible start/stop action. Join credentials
  remain in memory, the responsive grid represents participants without fake
  feeds, and all local/remote tracks are detached on leave, end, session loss,
  native screen-track end, or component teardown.
