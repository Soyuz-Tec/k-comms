# Changelog

## [Unreleased]

### Added

- Added a local-first instant workspace that opens directly into Excalidraw,
  restores a private device-local draft, supplies an editable guest identity,
  and promotes the scene and first message through the existing idempotent room
  contracts only when the visitor sends, shares, or explicitly starts a room.
- Made the draft Share action open the complete secure-link, native-share, and
  QR invite dialog immediately after durable room promotion.
- Added direct audio-call and video-call actions to the private workspace draft.
  Each action promotes the draft through the existing idempotent room contract
  exactly once, preserves the draft content, and opens the existing
  permission-aware prejoin flow before any media capture begins.

### Documentation

- Recorded the production two-iPhone cellular audio/video qualification for the
  managed LiveKit Cloud media plane while retaining the separate forced-relay,
  group-capacity, screen-share, privacy, outage, and incident gates.

## [0.3.0] - 2026-07-12

### Added

- Responsive user, tenant-administration, and content-blind platform-operations interfaces.
- Invitations and user lifecycle, tenant quotas, public channels, moderation, retention, legal holds, deletion workflows, and bounded neutralized audit CSV exports.
- Password recovery with one-time purpose-bound tokens, session/device invalidation, and rate limits.
- Scoped service accounts with one-time credentials, expiry, rotation, revocation, bot identity markers, and separate API routes.
- Canonical threads, explicit mentions, durable in-app notifications, and per-device encrypted browser-push subscriptions.
- Version-bound attachment intents, scan attempts, quarantine, and DNS-pinned provider HTTP protections.
- Hardened webhook secret storage, compare-and-swap delivery claims, retries, provider observability, and operations read models.
- Production Kubernetes overlay, controlled platform-role job, autoscaling, disruption budgets, network policies, alerts, dashboards, and local qualification/load runners.
- Automated browser journeys and backend, client, contract, manifest, secret, migration, release, restore, rollout, rollback, and resilience gates.

### Changed

- Advanced the repository from an executable messaging foundation to a complete staging-qualified communication-platform package.
- Made notification, attachment, governance, integration, administration, and operations workflows durable and auditable.
- Preserved server-readable encrypted-at-rest messages and deferred voice/video, federation, active-active multi-region writes, and true end-to-end encryption to dedicated future designs.
