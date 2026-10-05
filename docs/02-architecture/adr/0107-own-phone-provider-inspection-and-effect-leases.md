# ADR-0107: Own Phone provider inspection and effect leases

- Status: Accepted for default-off development
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

The additive migration retains receipts on rollback. An older application must
not replace this owner while consumed/applied effects remain;
`rollback_phone_provisioning_hazard_count/0` supplies owner evidence for release
compatibility integration. Disable management, reconcile effects and retain
history/control credentials before operational rollback. Actual carrier routing,
two-way media, provider permissions/version support and distribution remain
separate qualification gates. Source tests or inspection do not establish them.
