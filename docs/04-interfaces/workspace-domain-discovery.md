# Workspace domain discovery

The public gateway offers a workspace sign-in hint after explicit tenant opt-in
and a current exact DNS TXT ownership lease. It never discovers a person's
account, proves their email, enrolls them, or selects a trusted identity provider.

| Method and route | Input | Result |
| --- | --- | --- |
| POST `/api/v1/workspaces/discover` | `{domain}` only | `{data:{available,sign_in_path}}` |
| GET `/api/v1/admin/workspace-domains` | none | `{data:[claim],limits:{domains:8}}` |
| POST `/api/v1/admin/workspace-domains` | `{domain,version:0,discovery_enabled?:boolean}` | HTTP 201 `{data:claim}` |
| POST `/api/v1/admin/workspace-domains/:id/challenge` | `{version}` | Rotated 30-minute challenge |
| POST `/api/v1/admin/workspace-domains/:id/verify` | `{version}` | Consumed challenge, seven-day proof lease |
| PATCH `/api/v1/admin/workspace-domains/:id` | `{version,discovery_enabled:boolean}` | Updated opt-in |
| DELETE `/api/v1/admin/workspace-domains/:id` | `{version}` | Removed claim, retained Audit event |

The administrative claim includes `id`, `domain`, `version`, `status`
(`pending`, `verified`, or `expired`), `discovery_enabled`, `challenge_name`,
nullable `challenge_value`, `challenge_expires_at`, nullable `verified_at`, and
nullable `proof_expires_at`. Timestamps are ISO 8601 UTC with microsecond precision.
A consumed or governed challenge is never returned as a live TXT value.

Public unavailable results always use HTTP 200 and
`{data:{available:false,sign_in_path:null}}`. Public available results contain
only the validated relative route `/sign-in?tenant_slug=<stored slug>`. No email
input is accepted. An exact domain match does not extend to subdomains.

Administrative endpoints require a current human workspace owner/admin and
recent password/MFA identity proof. Missing version or proof returns 428;
current-identity denial returns 403; unknown or foreign claim ID returns 404;
stale version, occupied lease, missing proof, or expired challenge returns 409;
invalid input returns 422; DNS or an owner port being unavailable returns 503.
After CAS failure, reload current state before presenting a retry. A failed DNS
check preserves prior state and never displays verification success.

See [ADR-0097](../02-architecture/adr/0097-verify-opt-in-workspace-domain-discovery.md)
for retained-state governance and release gates.

The [operator runbook](../14-operations/workspace-domain-discovery-runbook.md)
describes renewal, revocation, erasure receipts and retained-state rollback.
