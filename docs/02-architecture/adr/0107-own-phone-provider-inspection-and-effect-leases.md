# ADR-0107: Own Phone provider inspection and effect leases

- Status: Accepted
- Qualification: Default-off development only; provider/carrier/runtime gates remain unrun
- Date: 2026-10-05
- Owners: Telephony, Identity, Security, Operations
- Related decisions: ADR-0085, ADR-0088, ADR-0089

Phone assignment previously accepted operator-supplied trunk IDs without inspecting
provider resources. LiveKit's SIP API manages trunks and dispatch rules, not
carrier number purchase, porting or ownership. Keep those distinctions explicit.

Telephony owns durable provisioning commands, assignment versions, 15-second
hashed effect leases and secret-free provider evidence. Inspect, Apply and
Reconcile are separate current-admin operations requiring persisted recent
step-up. Current active human workspace membership is checked for both actor and
assignee before every provider read/effect and local assignment. Immutable tenant,
session and device provenance is retained server-side; browser role claims grant
no authority. Assignment and receipt CAS prevent stale activation.

The provider adapter implements Telephony's port. Management defaults OFF and
uses existing protected LiveKit control credentials. Operators explicitly bind
each tenant to exclusive existing inbound/outbound trunk IDs and acquired DIDs.
No credential or arbitrary provider URL enters a client DTO, provider receipt,
audit metadata or log payload. The adapter returns only the selected IDs, DID,
safe dispatch-rule ID and observation time; provider passwords, headers,
metadata and unrelated tenant resources are discarded.

The configured provider dispatcher and its behaviour live in separate files and
use exact `status`, `inspect` and `apply` operations. A separate typed authority
port admits only the configured complete adapter and forwards leased IO through
the Telephony owner facade. Only that adapter calls its typed `authorize_io/3`
operation. The owner checks configured adapter identity through a separate internal
predicate module, avoiding a callback dependency through the public facade. No
generic dynamic operation dispatch or public lease-bearing HTTP route exists.
The strict manifest transition binds only this Phone contract/interface/table
delta and exact public-facade hash to immutable Member parent
`ba228342d830365c8ccf380d8d893bf3c1cd3605`. Existing enforcement, baseline,
foreign persistence restrictions and identity guards remain required.

Pin official LiveKit protocol `@livekit/protocol@1.52.1`, commit
`863261643ad83c8c7fc55e46f6a0e6ae36c85e4e`. Use the modern `dispatch_rule`
wrapper, `numbers=[called DID]`, one exact inbound trunk, no PIN and individual
randomized rooms with prefix `kc_tel_inbound_`. `inbound_numbers` restricts
callers and cannot substitute for the called-DID fence. Shared, wildcard,
conflicting, agent-configured or incompletely enumerated rules block activation.
Existing unique safe dispatch may be adopted without an external mutation.

Persist and consume one effect capability immediately before the bounded
CreateSIPDispatchRule request. A timeout, interruption or expired completion
after consumption remains uncertain. Never repeat Create for that command.
Reconciliation reads the exact original operation name/rule and current provider
bindings; absence alone does not prove that an earlier create cannot arrive.
An unresolved effect blocks another effect or manual assignment for the DID,
including another tenant after an operator mapping change. Expired unconsumed
leases cannot authorize late IO and therefore prove no create was dispatched.

Server requests are bounded and synchronous; durable receipts survive request
interruption. No background retry worker is introduced. The admin UI preserves
inspection UUIDs after network uncertainty and requires explicit step-up/CAS for
Apply or read-only Reconcile. Legacy manual setup remains available when
management is OFF; enabled management blocks that bypass. Calling admission is
controlled independently and is never enabled by applying provider setup.

The additive migration refuses down migration and retains receipts. Append only
`phone_provider_provisioning_v1` to the exact previous Member14 capability set.
An older application without that capability must not replace this owner while
any provisioning receipt remains, including failed or expired unconsumed
inspections. `rollback_phone_provisioning_hazard_count/0` counts every retained
row; the owner-only tenant fingerprint fragment includes every command UUID
without exposing identifiers, DID, snapshots or credentials in its report.
No provisioning worker, outbox dispatch or automatic retry is introduced, so
there is no separate Phone queue/orphan-job capability to attest. Receipts are
the durable authority for every synchronous request and uncertain external effect.
Image labels, both workload annotations, validators, operator receipt checks and
fingerprint parsing retain the same contract. Known M1 and Member14 targets stay
partial; current-image owner evidence decides their compatibility. Application
rollback does not authorize migration down or receipt deletion.

Management and empty bindings default OFF in every runtime template; one-shot
maintenance explicitly overrides inherited enablement and bindings. Only the
application service receives the two nonsecret management controls. No new
credential enters database, object storage, LiveKit sidecar or bootstrap service
environments. Production bundle validation rejects provider enablement until
separate qualification is implemented and approved.

Disable management, reconcile effects and retain history/control credentials
before operational rollback. Actual carrier routing,
two-way media, provider permissions/version support and distribution remain
separate qualification gates. Source tests or inspection do not establish them.
