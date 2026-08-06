# ADR-0071: Add client-side office call readiness qualification

- **Status:** Accepted for implementation
- **Date:** 2026-08-06
- **Owners:** Media, Web
- **Reviewers:** Architecture, Security, Release and Quality
- **Related requirements:** FR-COM-001, NFR-SEC-001, NFR-REL-001, ADR-0025, ADR-0049, ADR-0057

## Context

K-Comms has qualified a two-party cellular audio/video call over the normal UDP
path. That evidence does not prove that a particular remote office network can
reach signaling and media, nor does it exercise the TCP/TLS relay fallback
needed when UDP is restricted.

Operators need a repeatable test that a host can start without access to
provider consoles or browser developer tools. The test must include real
two-way speech: a synthetic network probe alone cannot prove that the office
participant can hear and be heard. It must not turn media diagnostics into a
new store of participant identity, IP addresses, credentials, SDP, or audio.

## Decision

K-Comms provides an audio-only **UAE office call test** from the Calls page.

1. The launcher creates a normal private group conversation and a one-use guest
   link expiring after 600 seconds. The existing hash-only guest credential,
   fragment transport, redemption, admission, authorization, audit, and call
   eviction rules remain unchanged. The general guest-link minimum becomes ten
   minutes; existing defaults do not become longer.
2. Host and guest launch the normal audio prejoin with an explicit
   `call_readiness=office` one-shot route parameter. Unsupported parameter
   values have no effect and launch parameters are removed after consumption.
3. Before joining, the LiveKit client runs sequential WebSocket, TURN,
   relay-microphone-publish, and reconnect checks with
   `iceTransportPolicy: relay`. The normal conversation-scoped participant
   token is not persisted or exposed.
4. The real room is also created with relay-only ICE policy. After connection,
   the LiveKit SDK's `force-tls` scenario requests the TCP/TLS fallback path.
5. When a remote participant is present and the local microphone is publishing,
   the client samples aggregate WebRTC audio statistics for 60 seconds. A
   person on each side must speak, and the local participant explicitly confirms
   that the office audio was audible.
6. A pass requires all preflight checks, a completed TLS relay switch, a
   selected TCP relay candidate, inbound and outbound audio packets, and audible
   confirmation. Packet loss above 3%, jitter above 50 ms, round-trip time above
   400 ms, or an unexpected reconnect produces a warning rather than a pass.
7. Results stay in browser memory. The optional JSON download contains only the
   bounded verdict, check states, aggregate packet/quality values, media region,
   codec, candidate class, and protocol. It contains no audio, names, user or
   room identifiers, credentials, SDP, candidate addresses, or raw RTC stats.

This feature is a qualification tool, not a regulatory or production approval.
A report from both physical endpoints is evidence for that exact test and
release. It does not close group capacity, screen-share, privacy approval,
provider-outage, incident-routing, or secret-rotation gates.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Rejection reason |
|---|---|---|---|
| Synthetic health endpoint only | Fast and automatable | Cannot prove browser permissions, media publication, office reception, or audible speech | Does not test the user journey |
| Persist raw `getStats()` output | Maximum diagnostic detail | May contain addresses and identifiers; creates a sensitive telemetry store | Violates data-minimization requirements |
| Provider-console qualification | Rich infrastructure telemetry | Requires privileged console access and cannot attest the user's actual office network state | Not self-service or independently repeatable |
| Record a test call | Easy human playback | Captures communication content and changes recording policy | Unnecessary for transport qualification |

## Consequences

### Positive

- A non-technical host can exercise the restricted-network route with a real
  office participant and export a reviewable result.
- The test reuses the production call, guest admission, and authorization
  boundaries rather than creating a parallel media path.
- Diagnostics are content-free and ephemeral by default.

### Negative and accepted trade-offs

- `force-tls` and WebRTC stats depend on browser and LiveKit SDK support. An
  incomplete sample fails closed instead of producing a false pass.
- The human audible confirmation is an attestation, not an automated acoustic
  loopback measurement.
- A relay-only test may consume more provider bandwidth than a normal direct or
  UDP call; the 60-second window bounds that cost.
- The conversation remains as a private conversation until the host archives
  it. The one-use invitation still expires independently after ten minutes.

## Security and privacy

- Existing conversation membership and call grants remain authoritative.
- The guest URL remains fragment-secret-bearing; readiness query parameters do
  not move or log the secret.
- The exported schema is an allow-list. It must not accept raw `RTCStats`, ICE
  candidates, tokens, participant objects, or room metadata.
- No new server persistence, background job, audit payload, or provider data
  grant is introduced.

## Validation

- Unit tests cover route scrubbing, link-secret preservation, verdict
  thresholds, media-stat reduction, and report minimization.
- Component tests cover the one-use 600-second invitation and prove that an
  office launch runs the four preflight checks, requires the microphone,
  selects relay-only ICE, and requests `force-tls`.
- The guest-link domain test accepts 600 seconds and rejects 599 seconds.
- Browser validation covers desktop and phone layouts without exposing the
  secret outside the invitation field/QR.
- Production qualification requires two physical endpoints, one on the target
  UAE office network, using the same immutable deployed digest.

## Revisit triggers

- LiveKit removes or changes `ConnectionCheck`, `force-tls`, or the relevant
  track statistics contract.
- Product requirements call for centrally retained readiness history, which
  requires a separate privacy model, schema, retention policy, and ADR.
- Automated acoustic verification becomes necessary.
