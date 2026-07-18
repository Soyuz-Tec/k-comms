# ADR-0018: Harden recovery identity, invitation, and session boundaries

**Status:** Accepted

## Context

The account email is also the password-recovery destination. Allowing an
ordinary authenticated profile request to replace it lets a stolen session
redirect recovery without proving control of either address. Similarly, an
invitation token is an enrollment credential, not proof that its holder owns an
already registered identity. Reusing invitation acceptance to reactivate a
suspended user could replace that user's password, role, and display name.

Rotating refresh tokens bound replay, but a purely sliding expiry could renew a
stolen session indefinitely. A durable upper bound must be independent of
rotation activity.

## Decision

- `users.email` remains the configured recovery identity and is immutable through
  the ordinary profile endpoint. A supplied email is accepted only as a
  case-insensitive, whitespace-normalized compatibility echo of the current
  value. A different value fails with `email_change_requires_verification`.
  A future change-email command must separately prove control and define its
  session-revocation behavior before this boundary can change.
- Invitations enroll only a new human identity. Invitation creation and
  acceptance fail with `invitation_identity_conflict` when the tenant already
  has that human email in any lifecycle state. Suspended users are reactivated
  only through the step-up-authenticated, versioned, reason-bearing admin
  lifecycle command; that command does not replace their password.
- Human sessions have both a sliding lifetime (`SESSION_TTL_SECONDS`) and an
  absolute lifetime. Session creation materializes the absolute deadline in the
  immutable `sessions.absolute_expires_at` field using
  `SESSION_ABSOLUTE_TTL_SECONDS` (30 days by default). Existing rows are
  backfilled to `inserted_at + 30 days`. Rotation sets expiry to the earlier of
  the new sliding deadline and that stored deadline. Refresh, access-token
  session lookup, socket-ticket mint/consume, step-up, and database-backed
  command/event authorization for established WebSockets require that both
  deadlines remain in the future.
- The database retains a UTC-normalized 30-day default for the
  `sessions.absolute_expires_at` column during the supported one-release
  rollback window. Current code always writes
  the configured deadline explicitly; the default exists only so the previous
  release, whose insert shape predates the column, can still create a session
  against the expanded schema. A reconciliation migration applies the same
  invariant to environments that received the first absolute-expiry migration
  before this rollback path was exercised.

This decision supersedes ADR-0017 only where it described invitation acceptance
as a suspended-user reactivation path. Its transactional quota and explicit
admin-unsuspend rules remain in force.

## Consequences

- A compromised session cannot silently redirect password recovery.
- An invitation holder cannot take over an existing active, suspended, or
  otherwise retained identity. Administrators retain an audited reactivation
  path, while the identity owner retains the existing password.
- Refresh rotation no longer extends a session past its creation-based upper
  bound. `SESSION_ABSOLUTE_TTL_SECONDS` is creation policy only: changing it
  affects new sessions and never moves an existing stored deadline.
- Email changes remain unavailable until a verified workflow is implemented;
  the Settings UI presents the recovery email as read-only.

## Alternatives considered

- **Allow email edits after normal authentication:** rejected because possession
  of a session is not proof of control over the old or new recovery address.
- **Let invitations reactivate suspended users:** rejected because the inviter
  receives the raw enrollment token and could replace another user's
  credentials.
- **Rely only on refresh rotation and inactivity expiry:** rejected because
  continuous use would have no fixed compromise window.

## Validation

- Core and HTTP tests prove different profile emails fail without persisting
  the display-name or email mutation, while normalized same-email echoes remain
  compatible.
- Invitation tests cover conflicts at creation and acceptance, including a
  suspended identity, and prove password, role, display name, and status remain
  unchanged. Admin unsuspend remains versioned and quota-controlled.
- Session tests prove the stored deadline is immutable, rotation is capped at
  that value even after configuration changes, and expiry denies refresh,
  active-session lookup, step-up, database authorization, and an established
  conversation channel.
- A previous-release-shaped raw session insert omitting
  `absolute_expires_at` succeeds with the 30-day compatibility default, and the
  reconciliation migration is exercised from the originally deployed
  no-default state in a non-UTC database session. The retained-image staging
  drill must also prove login after migration before release.
- The web test proves the recovery email is read-only and profile submission
  sends only the display name.
