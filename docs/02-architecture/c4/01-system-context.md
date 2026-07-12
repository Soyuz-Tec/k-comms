# C4 Level 1 — System Context

```mermaid
flowchart LR
    EndUser[End User]
    TenantAdmin[Tenant Administrator]
    Support[Support / Operations]
    Platform[Communication Platform]
    IdP[OIDC / SAML Identity Provider]
    Push[Push and Email Providers]
    Storage[Object Storage and CDN]
    Integrations[External Systems / Bots]
    Media[Optional WebRTC Media Platform]

    EndUser -->|HTTPS, WebSocket| Platform
    TenantAdmin -->|Admin UI / API| Platform
    Support -->|Restricted operations| Platform
    Platform -->|Authentication / provisioning| IdP
    Platform -->|Notifications| Push
    Platform -->|Signed upload/download| Storage
    Platform <-->|REST, webhooks, events| Integrations
    Platform <-->|Signaling and call authorization| Media
```

## Context notes

- The platform owns authorization and durable communication state.
- Identity providers authenticate or provision identities but do not authorize conversation access.
- Object storage owns binary durability; the platform owns attachment metadata and policy.
- Optional media infrastructure transports audio/video; Phoenix carries signaling, not RTP/SRTP media.
