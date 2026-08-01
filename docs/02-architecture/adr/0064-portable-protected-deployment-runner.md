# ADR-0064: Make the protected Proxmox deployment runner portable

- **Status:** Accepted
- **Date:** 2026-08-01
- **Owners:** Delivery, Operations, Architecture, and Security
- **Related decisions:** ADR-0055, ADR-0057, ADR-0058

## Context

ADR-0055 selected a persistent Windows self-hosted runner for the protected
Proxmox deployment job. The current official GitHub Actions runner archive was
verified against its GitHub-published SHA-256, but its runner executables are
not Authenticode-signed. Windows Smart App Control correctly refused to start
them after policy enforcement became active. The release workflow consequently
published and attested the application image but could not start staging.

Disabling Smart App Control, invoking the unsigned runner through an
alternative host, or manually deploying outside GitHub would weaken the
workstation or bypass the protected delivery chain. A GitHub-hosted runner
cannot reach the private Proxmox LAN.

## Decision

Refine ADR-0055's runner-host constraint: the protected deploy job may run on a
persistent Windows or Linux self-hosted runner that has the repository-scoped
`k-comms-deploy` label, PowerShell 7, OpenSSH clients, and `tar`. The workflow
does not select an operating system; it retains the `self-hosted`, `x64`, and
`k-comms-deploy` labels.

The deployment wrappers resolve `ssh`, `scp`, and `tar` through one
platform-aware helper. Windows uses the `.exe` commands when present; Linux
uses the native command names. The workflow uses `pwsh` on both systems and
uses the platform's native protected-file control: an explicit user ACL on
Windows and mode `0600` on Linux. Temporary secrets remain in the runner's
temporary directory and are deleted in the unconditional cleanup step.

Artifact provenance and SBOM verification continue on a GitHub-hosted runner
before the protected environment releases secrets. The deploy runner still
reconfirms that the approved revision is current protected `main`, uses strict
SSH host-key checking, and invokes the same digest-bound VM scripts. Staging,
production approval, backup, rollback, restore, and evidence semantics do not
change.

The immediate replacement runner is a persistent Linux runner in the existing
WSL2 virtualization boundary on the managed deployment workstation. It runs as
a non-root user and is launched through a limited-privilege host startup
control. This is an operational recovery for the control plane, not a change
to VM 101 or VM 100.

## Consequences

- Smart App Control stays enabled on the Windows host.
- A supported Linux runner can execute the protected workflow without
  pretending to be Windows or bypassing code-integrity policy.
- The deployment scripts gain a small portability seam that is testable on
  both Windows and Linux.
- The workstation and its WSL2 VM remain one availability boundary; an offline
  workstation still pauses deployments safely.
- The persistent runner remains mutable infrastructure and must be patched,
  least-privileged, and dedicated to this repository.

## Alternatives considered

| Alternative | Reason rejected |
|---|---|
| Disable Smart App Control | Weakens a host-wide security control and cannot be justified for one unsigned process. |
| Launch the runner assembly through another executable | Circumvents the same code-integrity decision instead of respecting it. |
| Deploy manually from the development shell | Bypasses protected environments, secret release, retained evidence, and serialized promotion. |
| Use a GitHub-hosted deploy runner | It cannot reach the private `192.168.1.0/24` deployment network. |
| Run the deployment worker on VM 101 or VM 100 | Mixes control-plane execution with a deployment target and weakens fault isolation. |

## Validation

- The Proxmox contract validator pins the OS-neutral runner labels, `pwsh`,
  Windows ACL, Linux mode, and shared native-command resolver.
- The native-command test runs on GitHub-hosted Linux before environment secret
  release and runs locally on Windows.
- The exact protected workflow must complete staging deployment, rollback,
  reactivation, isolated restore, and evidence export before production can be
  approved.

## Revisit triggers

- A dedicated managed runner VM or runner scale set replaces the workstation.
- GitHub ships an Authenticode-signed Windows runner compatible with the active
  code-integrity policy.
- The private deployment network becomes reachable through an approved
  identity-aware runner service.
