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
    Design[Accessible Design System]
    Media[Call Client\nConsent + Grid + Screen Share + LiveKit]

    Shell --> User
    Shell --> Admin
    Shell --> Ops
    User --> API
    User --> Realtime
    User --> Local
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
