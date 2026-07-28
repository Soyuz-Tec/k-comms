# ADR-0059: Treat Windows interface indices as diagnostic local-release evidence

- **Status:** Accepted
- **Date:** 2026-07-27
- **Owners:** Operations, Architecture, and Security
- **Related decisions:** ADR-0047, ADR-0051, ADR-0054

## Context

The Windows local-release receipt records an exact RFC1918 address, interface
alias, network name and category, explicit Public-profile authorization, and
the numeric Windows interface index observed at deployment. Start, Status,
Rollback, and a replacement Deploy previously required every recorded value to
remain identical.

Windows can renumber an otherwise unchanged adapter after a reboot or adapter
restart. That leaves the selected address Preferred on the same alias and
network profile, but blocks every manager lifecycle action, including the
documented deployment of a fresh receipt. The numeric index is therefore not a
stable security identity.

## Decision

Retain `interfaceIndex` in release receipts and status output as diagnostic
evidence, but exclude it from the topology-identity comparison.

The manager continues to fail closed unless all enforced observations match:

- the exact canonical RFC1918 address and Preferred address state;
- the interface alias;
- the Windows network name and category;
- authorization for a non-Private profile; and
- whether that authorization was actually required.

Forwarder process identity, configuration hashes, exact listener ownership,
loopback-only Podman publication, trusted-edge hostnames, and sealed public
origins remain unchanged.

## Consequences

A Windows-assigned index renumber no longer strands a healthy receipt or blocks
a clean replacement deployment. A real address, adapter alias, network,
profile-category, or override-use change still fails before activation.

Receipts remain comparable for investigations because both the deployment-time
and currently observed indices are printed. The index must not be used by
automation as proof of adapter identity.

## Alternatives considered

| Alternative | Reason rejected |
|---|---|
| Continue enforcing the numeric index | It is ephemeral and can make the documented recovery path impossible. |
| Edit the retained receipt after renumbering | It destroys immutable evidence and bypasses the manager transaction. |
| Remove all adapter and profile checks | It would allow meaningful network-topology drift and weaken the release boundary. |
| Introduce a receipt schema solely for an adapter GUID | A stable GUID may be considered later, but the existing alias, network, address, category, and authorization checks already preserve the required boundary. |

## Validation

- The network-observation self-test accepts an index-only renumber.
- The same self-test continues to reject address, alias, network name,
  category, and override-use drift.
- The Windows local-release CI gate parses and executes the manager validation
  suite.
- A retained trusted-edge deployment with a renumbered index can complete
  Status and a clean replacement Deploy without modifying old evidence.

## Revisit triggers

- Windows exposes a stable adapter GUID contract that should become receipt
  identity.
- The local-release manager moves away from Windows host networking.
- A future exposure mode no longer binds a selected RFC1918 address.
