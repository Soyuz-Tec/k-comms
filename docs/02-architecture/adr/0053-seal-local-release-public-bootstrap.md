# ADR-0053: Provision the local-release tenant through a sealed one-shot command

- **Status:** Accepted
- **Date:** 2026-07-25
- **Owners:** Delivery, Operations, Architecture, and Security
- **Related decisions:** ADR-0047, ADR-0050, ADR-0051

## Context

The supported local release needs a fixed tenant before the instant-room
surface can become available. The original manager started the packaged
application with `ALLOW_BOOTSTRAP=true` and then called
`POST /api/v1/bootstrap` through its loopback listener. In explicit private-LAN
mode the same application process was subsequently exposed through the host
forwarder, leaving an unauthenticated tenant-creation endpoint enabled for the
lifetime of the release.

Staging already uses `CommsCore.Release.bootstrap()`. That release command is
serialized in PostgreSQL, idempotent only for the same normalized tenant slug
and owner email, creates no browser session, and fails closed for a different
identity.

## Decision

Use the existing release command for local tenant provisioning and keep the
public application bootstrap endpoint disabled.

1. The local-release Compose topology contains a non-restarting `bootstrap`
   one-shot service. It uses the exact candidate image, a read-only root
   filesystem, the worker role, the one-shot runtime purpose, and
   `K_COMMS_LOCAL_RELEASE=false`.
2. `ALLOW_BOOTSTRAP` defaults to and is explicitly set to `false` for both the
   application and bootstrap service.
3. After the database is healthy and migrations succeed, the manager first
   queries for the configured active tenant. When absent, it runs
   `CommsCore.Release.bootstrap()` through the one-shot service and verifies the
   tenant postcondition directly in PostgreSQL before starting the application.
4. Every application activation additionally forces the Compose interpolation
   value `ALLOW_BOOTSTRAP=false`. This applies to deploy, start, restore, and
   rollback, including a retained legacy environment that recorded `true`.
5. A retained legacy release remains restartable only when its expected tenant
   already exists. If that tenant is absent and its retained Compose file has no
   sealed one-shot bootstrap service, activation fails closed and directs the
   operator to deploy a current candidate. The manager never falls back to the
   HTTP endpoint.
6. Release health requires `/api/v1/status` to report
   `capabilities.bootstrap=false` before any private-LAN forwarder is started or
   qualified.
7. Neither loopback nor plain-HTTP LAN text-only qualification creates
   disposable fixtures in the permanent bootstrap or fixed instant-room
   tenant. Before mutation, both modes write a schema-v3 cleanup marker and use
   the exact release image's non-restarting `qualification` one-shot service
   to create an isolated `k-comms-qualification-<id>` tenant. The
   create/delete command accepts only the fixed confirmation value and exact
   random 128-bit identity shape.
8. Both modes also start a temporary instance of the originating Compose
   `app` service with the exact image and revision, `K_COMMS_ROLE=edge`, the
   disposable tenant slug, and a random high port published only on
   `127.0.0.1`. `PUBLIC_APP_URL` remains the retained release's public origin.
   The temporary origin is admitted only through a qualification-specific,
   exact-origin CORS exception. The container's deterministic name, nonce,
   receipt hashes, labels, environment, hardening, listener, health, role, and
   image identity are verified before use.
9. Instant-room host creation occurs through that temporary origin. Its browser
   alone sends a qualification-id-derived documentation IPv6 address in
   `X-Forwarded-For`, and the temporary application trusts that value only from
   the exact source application-network gateway `/32`. The test captures the
   complete serialized host session in memory, closes the temporary context,
   and seeds a new public-origin context before its page boots. The guest opens
   the exact public share URL. Both public contexts omit forwarded-address
   headers and prove roster presence and two-way text through the retained
   application and, in LAN mode, the retained forwarder. Traces, screenshots,
   video, and AI failure-copy remain disabled for this bearer-bearing journey.
10. Cleanup re-verifies and removes the temporary application by inspected
    container ID, confirms its absence, deletes the exact disposable tenant
    through the originating one-shot boundary, and deletes the marker last.
    Crash recovery performs the same ordered operation before new work. A
    same-name container with mismatched identity is treated as a decoy and
    blocks both removal and tenant deletion. Legacy schema-v2 markers remain
    accepted only for tenant-only recovery; new work always writes schema v3.
11. The qualifier obtains a read-only, content-free fingerprint of the fixed
    instant-room tenant graph before disposable mutation and again after the
    cleanup path, even when an earlier browser, media, or cleanup gate fails.
    The tenant-presence flag, counts, and SHA-256 identity digest must match
    exactly; no ids, slugs, content, credentials, or bearer material are
    emitted.
12. The isolated instant-room specification remains anonymous-only. Optional
    account conversion stays in the loopback-only live guest specification,
    which verifies that converted state remains in the disposable tenant.
    Plain-HTTP LAN qualification still reads no account credentials and skips
    sign-in, conversion, account-authenticated guest links, audio, and video;
    it qualifies only the public anonymous roster/text path plus the existing
    transport and release gates.

The release remains one artifact, one PostgreSQL database, and one Compose
project. This is an administrative lifecycle command, not a new deployable
service or data owner.

## Consequences

### Positive

- A LAN-accessible runtime no longer exposes unauthenticated workspace
  creation.
- Tenant creation uses the same idempotent, sessionless mechanism as staging.
- Provisioning happens before the application or LAN forwarder becomes
  available.
- Restart and rollback enforce the sealed value even for a legacy retained
  environment.
- Repeated full qualification cannot accumulate disposable users,
  conversations, invitations, calls, or audit rows in the permanent tenant.
- Both qualification modes exercise the real retained public application path
  without creating an instant room in the fixed tenant.
- A failed or interrupted qualification retains enough secret-free,
  origin-bound identity to recover the temporary application before its
  disposable tenant, while refusing same-name decoys.
- The before/after fingerprint makes mutation of the fixed instant-room tenant
  a mandatory qualification failure independent of the primary browser gate.

### Negative

- A legacy receipt whose tenant was removed cannot recreate it and must be
  replaced by a current candidate.
- The protected local-release state still contains the initial owner password;
  operators must not copy it into logs, tickets, or qualification evidence.
- A hard host or Podman failure can interrupt cleanup; rerun the qualifier
  against the retained receipt to retry the marker-bound application-first,
  tenant-second recovery before discarding local state.
- A same-name container with mismatched identity intentionally blocks
  automatic cleanup until an operator investigates the decoy.

## Alternatives considered

| Alternative | Reason rejected |
|---|---|
| Keep the HTTP endpoint enabled only until the tenant exists | Requires an application restart and creates an avoidable network race. |
| Leave bootstrap enabled on loopback and rely on the LAN forwarder boundary | The application policy would still be unsafe if exposure changed or the forwarder were misconfigured. |
| Insert the tenant directly with `psql` | Bypasses IdentityAccess, tenant administration, initial-conversation, audit, validation, and transaction contracts. |
| Add another bootstrap implementation | Duplicates the existing staging-safe release command and increases drift. |

## Validation

- `python scripts/test_validate_local_release.py`
- `python scripts/validate_local_release.py`
- PowerShell parser validation for `scripts/manage_local_release.ps1`
- `powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 -Action Validate`
- Static and PowerShell self-tests cover schema-v3 marker binding, crash
  recovery order, same-name decoy refusal, legacy schema-v2 tenant-only
  recovery, and fixed-tenant fingerprint comparison.
- The live instant-room specification proves temporary-origin creation, full
  in-memory session rehome before public page boot, exact public-share
  navigation, no forwarded-address header on the public path, and retained
  public application/forwarder roster and two-way text.
- Static qualifier tests keep conversion in the loopback-only live guest
  specification and bind all converted state to the marker-cleaned disposable
  tenant.
- Exact-image deployment receipt plus `/api/v1/status` evidence showing
  `instant_rooms=true` and `bootstrap=false`

## Revisit triggers

- Local release moves behind an operator-authenticated provisioning API.
- The fixed instant-room tenant is replaced by a separately managed tenant
  lifecycle.
- Qualification cleanup schema v2 no longer needs tenant-only recovery
  support.
- Deployment receipt schema changes make the legacy activation override
  unnecessary.
