# ADR-0055: Operate a digest-promoted K-Comms release on dedicated Proxmox VMs

- **Status:** Accepted for the single-site internal production profile
- **Date:** 2026-07-26
- **Owners:** Delivery, Operations, Architecture, and Security
- **Related decisions:** ADR-0008, ADR-0012, ADR-0022, ADR-0025, ADR-0054

## Context

The selected internal production origin now runs on a dedicated Debian VM
inside one Proxmox VE host. PostgreSQL, MinIO, LiveKit, the Phoenix release,
and a Cloudflare Tunnel connector are co-located there. This is materially
different from the managed stateful-service target in ADR-0012 and from the
Windows qualification host in ADR-0054. It needs a reviewable deployment
contract before further production changes.

The GitHub Container workflow already publishes an immutable GHCR digest with
keyless build provenance and a CycloneDX SBOM. The remaining gap is controlled
promotion of that exact artifact, environment isolation, reproducible VM
runtime configuration, application-consistent backup, and evidence-backed
rollback.

## Decision

Use two dedicated Debian VMs on the selected Proxmox node:

| Environment | VM | Address | Purpose |
|---|---:|---|---|
| staging | 101 | `192.168.1.23` | LAN-only, synthetic-data rehearsal |
| production | 100 | `192.168.1.22` | authoritative internal production |

Each VM runs rootful Podman Quadlets owned by the repository package under
`deploy/proxmox`. Stateful volumes never cross environments. The production
VM keeps the Cloudflare connector and public hostnames selected in ADR-0054;
the staging VM has no public ingress and no production credential or data.

The existing production data volumes predate the Quadlet contract and keep
their Compose-created names. Their names are explicit environment
configuration, not implicit defaults. A one-time adoption operation verifies
the live container mounts and storage-format markers, takes a quiesced backup,
and moves service ownership from the retained legacy unit to Quadlets while
preserving the same application image and data in place. It has an automatic
fallback to the retained legacy service if activation verification fails.
Fresh staging and adopted production are distinct storage modes; production
may not silently create an empty replacement volume.

The retained Compose network owns `10.89.0.0/24`. To keep fallback independent
and prevent ambiguous network ownership, the production Quadlet network uses
the separately verified `10.90.0.0/24` subnet while staging keeps
`10.89.0.0/24`. The network subnet, gateway, Quadlet, and firewall DNS
allowance are rendered from one protected environment identity.

The adoption converter handles the legacy Compose environment parser's removal
of outer double quotes from `CSP_CONNECT_SOURCES`. The Podman runtime file
stores the unquoted exact trusted-edge value and rejects any content beyond
`'self'`, the configured LiveKit endpoint, and the configured object endpoint.

Promotion is `main` -> attested GHCR digest -> staging -> protected production
environment. The deployment workflow and host script both require the digest
and its exact 40-character source revision. Host activation additionally
checks the OCI source and revision labels. A mutable tag is never a deployment
input.

Application writers stop before migration or backup. A deployment takes a
verified PostgreSQL custom-format dump and a stopped MinIO volume snapshot,
runs forward-only migrations, activates the candidate Quadlet, verifies
readiness and release identity, and writes a non-secret receipt. Application
rollback runs the current release's communication-compatibility preflight and
does not run down migrations. Destructive database/object restore is a
separate operation with a fixed confirmation phrase, strict backup-path
validation, checksums, and archive inspection.

VM firewall policy admits administrative and media traffic only from the
trusted LAN. Production HTTP, signaling, and object listeners remain on
loopback for `cloudflared`; staging exposes only its test ports to the same
LAN. PostgreSQL, the MinIO console, Podman APIs, and Proxmox management are not
public application routes.

The Cloudflare connector is not `Requires`/`After` coupled to the application
systemd unit. It remains independently restartable during application
cutovers and fallback, and the production verification gate checks connector
activity plus origin readiness together.

## Consequences

The release path becomes reproducible, reviewable, digest-bound, and
rehearsable without copying authoritative data into staging. A failed
application activation can restore the preceding code identity, and explicit
backup evidence exists before every state-changing promotion.

This decision does not claim high availability. One Proxmox host, one
production VM, one PostgreSQL instance, local backup storage, and one tunnel
connector remain correlated failure domains. It also retains development
notification/scanner adapters for this internal profile; external or regulated
production requires the managed-provider and multi-origin gates already
described by ADR-0012 and the production runbooks.

## Alternatives considered

| Alternative | Reason rejected |
|---|---|
| Update the production VM directly from a source checkout | It bypasses immutable artifact identity, attestations, staging rehearsal, and deterministic rollback. |
| Clone production into staging | It copies authoritative data and credentials into a lower-trust environment. |
| Keep ad hoc `podman run` commands | They are not drift-detectable, reviewable, or automatically restored at VM boot. |
| Claim the single host as highly available | Every runtime and storage component still shares one physical failure domain. |
| Move immediately to Kubernetes or microservices | It expands operational complexity without resolving the immediate promotion and recovery-control gap. |

## Validation

- Static validation checks the complete Proxmox package, pinned infrastructure
  images, immutable application reference contract, restricted listener
  topology, secret placeholders, workflow environment gates, and tests.
- Staging qualification deploys the exact `main` digest, bootstraps synthetic
  data, verifies services and identity, takes and checks a quiesced backup,
  rehearses rollback, and reactivates the candidate.
- Production qualification verifies the retained public endpoints, Cloudflare
  connector, exact running digest/revision, timers, backup location, listeners,
  and authoritative record counts without copying or mutating production data.
- One-time production adoption verifies exact legacy mounts, PostgreSQL and
  MinIO format markers, a pre-cutover logical/object backup, unchanged
  application identity, disabled legacy startup, and a successful
  post-adoption production health gate.
- A separate Proxmox backup schedule complements, but does not substitute for,
  the application-level PostgreSQL and MinIO recovery proof.

## Revisit triggers

- A second production origin or Proxmox node is introduced.
- PostgreSQL PITR or an independent encrypted backup target is added.
- A managed stateful service replaces a co-located component.
- External Internet users or a formal production SLA require redundant
  signaling, object storage, TURN, database, or tunnel paths.
