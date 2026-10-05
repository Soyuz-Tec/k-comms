# Phone provider setup

Management is OFF unless `TELEPHONY_PROVISIONING_ENABLED=true`. Calling remains
independently controlled by the existing telephony flag. Supply the existing
protected LiveKit API settings and operator-owned `TELEPHONY_PROVISIONING_BINDINGS`
as bounded JSON mapping tenant UUIDs to `inbound_trunk_ids`,
`outbound_trunk_ids` and `phone_numbers` lists. Each list must be nonempty; IDs
and DIDs must be unique across tenants. This setting contains no passwords.
No carrier account or provider credentials were supplied during development.

Acquire and route a DID with the carrier and create its LiveKit trunks outside
this client. The UI inspects only the operator-bound trunk IDs, verifies the DID
on both and either adopts a unique safe individual dispatch rule or explicitly
creates that rule. It cannot buy/port numbers, change SIP credentials, add
unrestricted dispatch, activate agents or turn on calling.

Use Workspace Admin → Phone → provider bindings. Inspect with an eligible active
human workspace assignee and extension. Review the receipt and Apply with current
password verification and a change reason. Apply rechecks the current owner,
assignee, assignment version and provider resources. Validate actual inbound
ringing/answer/reject, outbound caller ID, two-way audio and hangup separately.

If Apply's outcome is uncertain, refresh receipts and choose Reconcile original
effect. Reconciliation never sends Create again. If the original rule remains
missing/conflicting, keep management/calling off and investigate the exact
`kcomms-phone-<command UUID>` operation with the provider. Do not create a second
rule or clear the durable receipt to make the UI appear ready. Retain control
credentials while an external effect may need reconciliation.

Official protocol source: https://github.com/livekit/protocol/blob/863261643ad83c8c7fc55e46f6a0e6ae36c85e4e/protobufs/livekit_sip.proto
(release `@livekit/protocol@1.52.1`, SHA256
`c73d015eee1fe27082a9b60be6eac51d0b75a4dc5b44602b9447221398330bd2`).
Compatibility with the operator's deployed provider version and permission grants
requires qualification; no real provider request was made during source work.

Required gates after source review: migration/owner/controller/adapter tests,
strict architecture/public-facade validation, web typecheck/unit/build and
operator-owned synthetic provider journeys. Local source/light checks do not
qualify production provider effects. Apply migration before enabling management.

The exact HTTP routes are `GET /api/v1/admin/telephony/provisioning`,
`POST /api/v1/admin/telephony/provisioning/inspect`,
`POST /api/v1/admin/telephony/provisioning/{commandId}/apply` and
`POST /api/v1/admin/telephony/provisioning/{commandId}/reconcile`. The latter two
address an actual command UUID and require its current `version` and a change
`reason`; inspection requires a UUID `idempotency_key`, the current
`assignment_version` (zero before assignment) and the five exact assignment
fields. Every write requires current eligible tenant administration, persisted
recent step-up and secure transport. Responses are `Cache-Control: no-store`.
Inspect the exact secret-free payload contracts in
`contracts/json-schema/phone-provider-provisioning.v1.json` and mirrored OpenAPI.

Release metadata appends only `phone_provider_provisioning_v1` to the previous
Member14 set. A target lacking it is refused whenever **any** command is retained,
including failed/expired unconsumed receipts. Fixed-tenant release fingerprints
count and hash command identities without printing them. There is no Phone
provisioning worker, automatic retry or durable queue to clear. Do not delete
receipts, down-migrate `20261006000700`, remove required control credentials or
rewrite an old image's immutable capability label to force a rollback. Reconcile
original effects explicitly, retain all evidence, and roll forward or use an
approved compatible bridge release. Disabling the flag does not erase hazards.

All Kubernetes and Proxmox defaults keep management OFF with `{}` bindings.
One-shot migration/bootstrap/preflight/remap/role maintenance also sets OFF/`{}`
even if application configuration is enabled. The application-only service
environment allowlist carries the two nonsecret owner controls; neither belongs
in another service environment. Production bundle validation remains closed to
provider enablement while the separate carrier/provider gates are unqualified.
