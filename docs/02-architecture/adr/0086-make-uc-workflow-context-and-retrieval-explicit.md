# ADR-0086: Make UC workflow context and retrieval explicit

- **Status:** Accepted
- **Date:** 2026-10-04
- **Owners:** Web, Identity, ConversationContent, Administration, Telephony
- **Related decisions:** ADR-0019, ADR-0025, ADR-0057, ADR-0085

## Context

The UC interface assessment identified workflows that lost their destination,
presented a loaded page as a complete search, or conflated configuration with
successful calling. These gaps affect the existing product before calendar,
recording, or advanced PBX features can be added. Existing commands already
provide authorization, version checks, privileged reauthentication, and audit
reasons; improving their presentation must preserve those controls.

## Decision

Preserve member destinations through authentication using an allowlist of
internal routes and supported, non-secret query fields. Reject external and
malformed return targets. Carry guest bearers only through existing fragment
admission or temporary router state, consume that state on entry, and never
place a bearer in a sign-in or password-recovery query string. An explicitly
unavailable board is an error; it must not silently select another board.

Apply file category and filename filters in the existing authorized file query
before pagination. Add `category=images|non_images`; omit it for all MIME types.
Reuse bounded literal filename search and active conversation membership. Do
not expose storage identities, fetch unsafe previews, or introduce a file-drive
authorization model.

Expose bounded audit list filters through Administration using the same query
predicates as export. Preserve both date boundaries and continuation cursors,
return a null cursor at the terminal page, and record only whether free text
was supplied in audit-read metadata. The tenant always comes from the current
authorized subject. No client-selected tenant or new context boundary is added.

Expose `provider_ready` and `line_assigned` separately in phone configuration.
The former means enabled deployment configuration is valid; it does not mean
the carrier, trunk, number, network, or media path has been qualified. Preserve
the combined `configured` field. Personal history remains independently
readable under its existing owner authorization when admission is unavailable.

Use existing mutation commands for thread actions, webhook edits, retention,
moderation, and workspace administration. Local filters over bounded inventories
must state their loaded scope. Preserve server ownership checks, optimistic
versions, idempotency, recent-password gates, and audit reasons.

Keep browser device preferences local and bounded. Device enumeration does not
grant capture. Microphone, camera, and speaker tests require an explicit action,
stop when settings closes, and respect conversation and phone media ownership.
No test starts a room, calls a provider, or records media. A local speaker tone
is device testing, not proof of a remote audio path.

## Consequences

The contracts gain additive query fields and phone configuration booleans. No
migration, new business context, architecture exemption, provider enablement,
or secret is required. Legacy phone responses retain a client fallback while
the current server returns the explicit fields.

Navigation, settings, and guided setup expose existing capabilities more
clearly. Meeting history remains a room lifecycle; phone history remains an
individual outcome. A pre-call number keypad is not in-call DTMF. Gallery,
speaker, and pin controls change local presentation without granting participant
authority or changing the media topology.

This decision closes the reliability and discoverability increment in the
[UC gap delivery plan](../../13-delivery-plan/uc-gap-closure-delivery-plan.md).
It does not declare scheduling, recording, carrier qualification, advanced
telephony, SSO, or presence complete.

## Validation and rollout

Qualify destination validation and bearer hygiene with negative tests; exercise
file and audit queries with tenant, membership, wildcard, boundary, and cursor
cases; exercise UI actions with delayed failures and retained drafts. Browser
tests cover real rendered desktop/mobile navigation, search scopes, thread
actions, phone history, file filtering, and accessibility against synthetic API
responses. These tests do not qualify a real carrier or physical iOS media.

Use the normal protected immutable release chain. Roll back the application
digest if required; retain existing data and telephony records. No schema
rollback or production data operation is needed. Provider activation remains a
separate provisioned and qualified operation under ADR-0085.
