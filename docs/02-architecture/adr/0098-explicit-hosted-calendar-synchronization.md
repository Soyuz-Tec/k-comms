# ADR 0098: Explicit hosted-calendar synchronization

Status: Accepted
Date: 2026-10-05  
Owners: Calls, Identity, Governance, Integrations

## Context

Scheduled meetings export ICS, but do not synchronize a calendar. Full UC needs
an explicit delegated connection, durable updates and cancellation, visible
conflicts, and recovery after an uncertain external effect. Calendar export
creates another retained copy of title and authorship metadata. Local meeting
scrubbing alone cannot complete governed erasure of that copy.

This increment is one-way: an active workspace human opts in their hosted
K-Comms meeting occurrences into their own primary Google or approved Microsoft
Entra calendar. It exports title, UTC start/end, the source timezone label and a
token-free authenticated workspace link. It exports no attendee email, member
list, phone number, description, guest token or media. Import, free/busy,
external-to-K-Comms edits, shared calendars and provider webhooks are separate
increments. ICS remains available independently.

## Decision

Calls owns encrypted OAuth challenges, connections, historical source lineage,
meeting opt-ins, stable event mappings, durable commands and erasure receipts.
Identity owns exact current workspace-human authority. Governance owns the
tenant capture/hold seal. Integrations owns fixed-host, bounded delegated OAuth
and calendar protocols, with no Repo access. Workers deliver persisted command
identifiers through an exact registered owner port.

The canonical order is Governance tenant/capture/protection fence first, then
tenant admission, Tenant SHARE, sorted User NO KEY UPDATE, exact Device/Session
SHARE for interactive commands, then Calls connection, meeting, mapping and
command rows. Acquiring the Governance parent after User would create a cycle
with existing governed deletion. Interactive completion revalidates the exact
initiating session, scope and recent step-up after all provider waits and before
commit. Offline export retains active tenant and workspace-human authority plus
current policy, connection consent generation and source authority; it does not
invent a live app session. Cleanup permits expired/suspended identity only for
the exact previously managed objects and credentials under its retained seal.

An owner transaction has a 15-second absolute budget, SQL waits bounded by the
remaining budget and a 20-second Repo timeout. Network hops share at most five
seconds including DNS, token, JWKS, account binding and event requests. Existing
PinnedHttp callers keep their normal timeout; the calendar adapter supplies an
additional absolute owner deadline. Redirects are not followed. Response bodies
are capped at 256 KiB, headers at 16 KiB/60 fields, JSON at depth 12 and bounded
field/list sizes. Providers and export policy default closed.

### Delegated OAuth and encryption

Each browser flow uses Authorization Code, PKCE S256, a one-use five-minute
state challenge, signed ID-token nonce and an HttpOnly Secure SameSite browser
binding. The exact initiating tenant/user/device/session is persisted. Callback
does not sign in an identity and redirects only to a fixed relative calendar
settings route with an opaque local result. Raw code, token or provider body
never enters Audit, logs, browser status, Ops or job arguments.

Google requests `openid` and `calendar.events.owned`; Microsoft requests
`openid profile offline_access` and delegated Graph `Calendars.ReadWrite` for
one explicitly approved tenant UUID. There is no `common` expansion,
application mailbox permission, User.Read, email or broad session-revocation
scope. New offline connections need a usable refresh token. Refresh rotation
is generation CAS; an omitted refresh token can retain an existing bound token,
but cannot complete an initial connection. Broader returned scopes fail closed.

The adapter verifies RS256 using fixed provider JWKS, a unique key ID and at
least RSA 2048, exact issuer/audience/authorized party, bounded expiry/issuance,
nonce, stable subject and Microsoft's tenant/object UUID. Mutable email is not
an identity key. Each event operation additionally compares the current access
token's provider-native UserInfo `sub` with the verified connection's OIDC
subject. The existing `openid` permission suffices. UserInfo names/emails are
discarded. Thus another account's plausible event 404 cannot prove absence.

Calendar SecretBox has its own purpose-bound AES-256-GCM keyring; it never uses
Identity, MFA, password, service or provider secrets as encryption keys. AAD
binds tenant, user, provider, resource, generation, purpose and key ID. Current
and previous keys allow verified rotation. Missing/unknown keys or tampered AAD
fail closed. Material remains encrypted until exact cleanup completes.

### Stable commands and truthful outcomes

Mapping identity uses connection generation plus meeting UUID and occurrence
sequence, not the regenerated occurrence-row UUID. An opaque mapping UUID is
the Google deterministic hexadecimal event ID and Microsoft transactionId and
exact named extended-property marker. Outbound intent is committed in the same
owner transaction as accepted source edits/cancellation. Unacknowledged effects
remain uncertain; they are reconciled before retry or erasure completion.

The adapter creates no attendees. Google uses `sendUpdates=none`; this alone is
not a guarantee that the provider sends no email under every external edit.
Microsoft uses ImmutableId preference consistently. Writes use current verified
If-Match etags. A 409/412 or external removal is an explicit conflict, not an
automatic overwrite/recreation. Explicit versioned resolution either exports
current source after a fresh provider read or stops syncing. External text is
never imported or displayed as trusted workspace data.

Google recovery GETs the exact deterministic ID and verifies the private opaque
marker. Microsoft recovery filters its exact extended-property marker with
`$top=2`; it never performs a whole-calendar dump or assumes transactionId is
filterable. Duplicates or a continuation remain a cleanup problem. Removed
occurrences and consent generations have irreversible tombstones; late results
cannot resurrect a deleted intent. Auth failures stop new writes; transient
429/5xx/timeouts have bounded retry and an observable safe category.

Removal accepted and exact-account authenticated absence are distinct receipts.
Disconnect first fences export/refresh, then removes/reconciles all managed
objects, then revokes when supported and destroys local credential material.
Google confirms its narrow token revocation separately from event removal.
Microsoft has no equivalent narrow revocation endpoint: it reports local
disabled/external grant unconfirmed and links to provider-native user consent
controls. It never calls broad revokeSignInSessions. A tenant requiring narrow
centrally provable grant revocation must remain unsupported until a separately
approved provider-native mechanism exists.

### Governed erasure and release

Unknown historical author lineage and legal holds fail closed. Preparation seals
new export/refresh and queues exact managed-object deletion or uncertain-create
reconciliation. Governed completion waits for all exact-account removal proofs,
credential/challenge destruction and no live uncertain writers. Wrong-account
404, 401/403, revoked token, local tombstone or cancelled status is insufficient.
Provider backup retention limits are stated separately; normal API removal does
not prove physical erasure from inaccessible provider backups.

Owner schema migrations are additive and initially opt no meeting into export.
Retained credentials, mappings, commands, receipts and author lineage are owner
rollback hazards. `calendar_sync_v1` and `calendar_erasure_v1` are immutable
target-image capabilities. Missing capability requires quiescence and zero
verified owner hazards. Down refuses retained state unchanged. A disposable
synthetic down/up drill is not production rollback authority.

## Implementation and qualification state

This isolated increment contains dedicated SecretBox and typed provider ports,
fixed Google/Microsoft delegated OAuth/event adapters, owner persistence,
one-use browser-bound challenge consumption, authenticated owner API,
source-transaction command insertion, registered worker/reconciler, current
eligibility fencing, Governance completion barriers, release inventories and
Profile/Meeting/admin controls. Each meeting requires explicit hosted-meeting
opt-in. Providers remain disabled by default and provider-qualified status
remains false. This describes authored source, not runtime qualification.

The Calendar source integrates the Member/History parent checkpoint.
Required gates then include compile warnings as errors, architecture source and
actual xrefs with unchanged baseline, meaningful real PostgreSQL wait/revocation
races, adapter security tests, HTTP/browser proof, migration refusal, synthetic
provider uncertainty/recovery and governed erasure. Tests using a local adapter
prove protocol behavior, not real calendar-provider acceptance.

Actual provider qualification requires deliberately authorized synthetic app
registration/accounts and real consent, expired-token refresh, create/update,
external conflict, explicit resolution, cancellation/absence, lost-ack recovery,
unlink and governed erasure without changing unrelated events. Neither provider
is registered, configured or called by this source increment. Normal protected
delivery and immutable staging/production gates still apply.

## References

- [Official Google calendar authorization](https://developers.google.com/workspace/calendar/api/auth)
- [Official Google insert protocol](https://developers.google.com/workspace/calendar/api/v3/reference/events/insert)
- [Official Google OIDC discovery](https://accounts.google.com/.well-known/openid-configuration)
- [Official Graph event creation](https://learn.microsoft.com/en-us/graph/api/calendar-post-events?view=graph-rest-1.0)
- [Official Microsoft UserInfo and delegated permissions](https://learn.microsoft.com/en-us/entra/identity-platform/userinfo)
- [Official broad Microsoft session revocation](https://learn.microsoft.com/en-us/graph/api/user-revokesigninsessions?view=graph-rest-1.0)
- [Development-to-production standard](../../14-operations/development-to-production-completion-standard.md)

Official documentation and discovery were read on 2026-10-05 using anonymous
public GETs. Those reads are not real OAuth/calendar qualification.

## Integration and qualification boundary

The Calendar table migration 20261006000300 owns only Calls tables. The separate
TenantAdministration migration 20261006000310 owns the opt-in export policy.
Their down guards are literal owner-only inventories, run before their DDL.
No historical parent migration, architecture validator, or baseline exception
is widened. The original unpublished mixed migration is retained privately for
review; this split changes ownership composition without changing its intended
final schema. The unpublished erasure-receipt version constraint is also
corrected from a fixed value to a positive monotonic version so repeated
pending/proven preparation can retain its current proof state.

Meeting mutation retains a typed prelock receipt before any Meeting row lock
and consumes it on the same transaction after the mutation. Its record phase
never reacquires Connections. User-held lifecycle callbacks only fence and
queue cleanup; they do not enter Governance or providers, and ordinary logout
keeps offline consent. Same-principal cleanup reauthorization cannot clear a
consent fence, resurrect a mapping or enable new exports.

Provider 404 for a known object, accepted delete, and Graph duplicate or
continuation results remain pending until bounded scoped reconciliation proves
all managed copies absent. A Microsoft external-unconfirmed grant revoke is
not a Governance completion proof. Expired grants remain pending. The current
source increment has authored tests and static checks; backend/HTTP/browser,
migration and live-provider qualification are pending and are not claimed here.
