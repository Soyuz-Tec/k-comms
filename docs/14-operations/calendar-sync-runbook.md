# Hosted Calendar export

ADR-0098 implements optional one-way copies of explicitly selected hosted
meeting occurrences. Google uses `calendar.events.owned`; Microsoft uses
delegated `Calendars.ReadWrite` and offline access for one configured Entra
tenant. It does not import events or invite attendees. Members see the title,
time, time zone and authenticated workspace meeting link that will be exported.

Both providers default off. Authored source and synthetic tests do not qualify
a live provider. The status API reports configuration and qualification as
separate facts; current provider-qualified status remains false.

## Configuration

Use an HTTPS `PUBLIC_APP_URL` on port 443. Register the exact callbacks
`/api/v1/calendar/oauth/google/callback` and
`/api/v1/calendar/oauth/microsoft/callback` on that origin. Never permit arbitrary
callback origins or redirect targets.

Supply `CALENDAR_SECRET_ENCRYPTION_KEYS` as one to eight exact
`key_id:Base64-of-32-random-bytes` entries, separated by commas. Select one entry
with `CALENDAR_SECRET_ENCRYPTION_KEY_ID`. Keys must be distinct from Identity,
push, webhook, history-signing and provider credentials. Retain old keys until
their encrypted credentials, challenges and remote mapping material have been
removed or reencrypted under qualified owner operations. Removing an old key
can make cleanup impossible and therefore leave erasure pending.

Set the selected `CALENDAR_{GOOGLE,MICROSOFT}_CLIENT_ID` and client secret.
Microsoft additionally requires the exact canonical Entra tenant UUID in
`CALENDAR_MICROSOFT_TENANT_ID`; common/organizations/consumer tenant selectors
are refused. The keyring and client secrets support mutually exclusive `_FILE`
inputs selecting private regular files directly below `/run/secrets`. Never
put secrets in tenant settings, API responses, browser local storage, logs or
configuration maps.

The Proxmox service environment forwards these controls and secrets only to
the application. Kubernetes uses `k-comms-provider-secrets` for Calendar
secrets and its ConfigMap for non-secret controls. One-shot Kubernetes jobs
explicitly disable both Calendar providers and receive no Calendar provider
credentials. Operators must provision any private-file mounts themselves;
the examples create no files or credentials.

Set `CALENDAR_GOOGLE_ENABLED` or `CALENDAR_MICROSOFT_ENABLED` only with approved
configuration and qualification evidence. Enable tenant Calendar export through
the authenticated admin settings UI. Each connection and each meeting still
requires the member's explicit consent and current step-up proof. Configuration
does not cause automatic export.

## Pending cleanup and conflicts

Meeting changes retain stable managed occurrence markers. External conflicts
require an explicit reexport of the current meeting version or stop-syncing
decision. Reexport obtains fresh provider state and ETag; it does not force an
old ETag or blindly retry an uncertain create.

Withdrawal of workspace eligibility or tenant policy fences consent and queues
cleanup. Ordinary logout preserves offline consent. User-held lifecycle
callbacks perform local fencing only; providers run from the registered bounded
Calendar worker after the Governance seal and retained owner parent locks.

Accepted deletion and a 404 for one known event remain pending until scoped
marker reconciliation proves all managed copies absent. Microsoft duplicate or
continuation results remain pending. An expired grant remains pending and
retains its encrypted immutable account/mapping material. Cleanup-only
reauthorization must use the same provider principal; it cannot resume export,
clear tombstones or discard old cleanup obligations.

Microsoft grant revocation is reported as `external_unconfirmed` after local
credential destruction. Removing the app grant through Microsoft's account
permissions is a separate operator/member action. The software does not treat
that disclosure, a screenshot or local token destruction as a verified remote
grant-revocation receipt. Governance remains pending while required proof is
unavailable. Legal holds block destructive cleanup.

Inspect only content-free status/count projections and restricted qualification
evidence. Never run blanket provider deletion, discard uncertain mappings or
reset command attempts to make a cleanup count reach zero.

## Release and rollback

Repeated preparation reuses only an absence proof committed after an immutable
tombstone, with all earlier mapping intents terminal and private boxes erased.
It cannot reopen a verified cleanup. Receipt versions remain positive and
advance on each preparation.

The target image must declare `calendar_sync_v1` and `calendar_erasure_v1`.
Rollback preflight inventories all six Calendar owner tables, tenant policy and
active Calendar jobs. A target lacking a required capability must refuse
retained hazards. Inventory failure is a refusal.

Migration `20261006000300` owns six Calendar tables. Migration
`20261006000310` owns two tenant policy fields. Both down guards inspect retained
state before DDL, and the policy down guard invokes the public Calendar owner
inventory before removing policy fields. A disposable empty down/up exercise
does not authorize a production downgrade. Use a compatible roll-forward or
the separately authorized backup/restore process for retained state.

Backend/HTTP/browser, concurrency, migration and live-provider qualification are
pending for this source checkpoint. Record exact source/image hashes and
synthetic unrelated controls for every qualification attempt. Provider-native
absence proof describes accessible owned objects, never inaccessible backups.
