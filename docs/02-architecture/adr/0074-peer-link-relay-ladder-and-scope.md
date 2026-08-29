# ADR-0074: Give the peer link a relay ladder, a scope boundary, and outcome telemetry

- **Status:** Proposed
- **Date:** 2026-08-29
- **Owners:** Media, Web
- **Reviewers:** Architecture, Security, Operations, Release and Quality
- **Related requirements:** FR-COM-001, NFR-SEC-001, NFR-PERF-001, NFR-REL-001,
  ADR-0025, ADR-0057, ADR-0071, ADR-0072, ADR-0073

Decision 6, the outcome telemetry, is implemented ahead of approval because it
adds no dependency and because the measurement is what decides whether the rest
of this ADR is worth accepting. Decisions 1 to 5, 7, and 8 remain proposed and
unimplemented.

## Context

ADR-0072 and ADR-0073 shipped an opt-in, one-to-one, audio-only WebRTC path
between two K-Comms endpoints. Signaling is relayed through the authorized
`call:<call_id>` topic under a deterministic state machine, SDP is constrained
to a single audio section, quotas are replica-independent, and LiveKit remains
the control plane and the terminal fallback.

`CommsWeb.DirectAudio.ice_servers/0` returns Cloudflare STUN and nothing else.
That leaves three gaps.

1. **There is no relay rung.** Host and server-reflexive candidates do not
   traverse symmetric NAT or a UDP-blocking corporate firewall. Those are the
   exact networks the pilot targets: the office endpoint qualified by ADR-0071
   needed a TCP/TLS relay to pass at all. Every such endpoint pair returns to
   the SFU, and under ADR-0057 the SFU is LiveKit Cloud's free Build plan, so
   the fallback consumes the metered provider bandwidth the peer link exists
   to avoid.
2. **Nothing measures the outcome.** ADR-0072's revisit trigger is "direct
   success rates justify a credentialed TURN service", but the direct-path
   state is client-visible only and is never aggregated. The trigger cannot
   fire because nothing counts it.
3. **The boundary is implemented but not stated.** "One-to-one audio" lives in
   `DirectAudio.authorize/3`, the Presence peer limit, and the SDP grammar. It
   is not written down as an architectural rule, so group mesh, direct video,
   and multi-device keep returning as open questions.

There is also an unoffered privacy choice. On the SFU path, SRTP terminates at
the provider, which therefore holds decrypted media. On the peer link,
DTLS-SRTP stays end to end, but the peer learns address information — and
because microphone permission is already granted, browsers no longer obfuscate
host candidates with mDNS names, so the peer sees the LAN address as well as
the public one. Today a participant chooses between these two properties
implicitly, through a checkbox labelled for latency.

## Decision

Adopt **peer link** as the named primitive: an authorized, ephemeral,
exactly-two-endpoint WebRTC transport belonging to one active call, negotiated
over the authenticated call topic, with LiveKit as the control plane and the
terminal fallback. A peer link is never the control plane, never a mesh, and
never a durable record.

1. **ICE priority is the ladder.** Relay servers join the existing ICE session
   instead of triggering a second negotiation. Candidate priority already
   orders host above server-reflexive above relay, so the ladder needs no new
   signaling state, no change to ADR-0073's state machine, grammar, or bounds,
   and no extra rung latency. `iceCandidatePoolSize` stays 0 and trickle
   continues. The client's existing 12-second attempt budget is unchanged, and
   exhausting it remains terminal for that attempt.
2. **Relay credentials are call-scoped and minted server-side.**
   `CommsWeb.DirectAudio.ice_servers/0` becomes `ice_servers/1`, taking the
   already-authorized call context and returning the STUN entry plus at most
   one relay entry. The relay credential carries a TTL no longer than the
   participant-token TTL of 300 seconds, and its identity is an opaque digest
   of tenant, call, and peer ID — never a user, device, or session identifier.
   It is delivered only in the requesting socket's own join reply, and is never
   broadcast to the peer, written to the database, audit log, outbox, or
   application logs.
3. **The relay provider is configuration behind an existing boundary.**
   `CommsIntegrations.Audio.IceServers` already mints coturn REST
   (`use-auth-secret`) credentials for the SFU path; the peer link reuses that
   boundary with a direct-scoped identity. The recommended first provider is a
   hosted TURN service reachable over `turns:` on 443/TCP, with UDP where
   available, because it keeps the residential edge closed — the constraint
   ADR-0057 accepted. Self-hosted coturn beside LiveKit becomes the preferred
   option only when a datacenter or office edge exists with a stable address,
   certificate lifecycle, and abuse controls. Plaintext `turn:` stays rejected
   outside the local-development adapter gate.
4. **Two transport preferences, both explicit.** Prejoin offers *Prefer a
   direct connection* (`iceTransportPolicy: "all"`, unchanged) and *Private
   direct connection* (`"relay"`), which hides both endpoints' addresses from
   each other while still keeping media unreadable by K-Comms and by the SFU
   provider, at the cost of one relay hop. Consent text is written per mode and
   states what that mode discloses. Neither mode adds an end-to-end-encryption
   product claim: there is no key verification, no group story, and no
   supported attestation.
5. **The scope boundary is a rule.**
   - Exactly two endpoints per peer link. Group and channel calls stay on the
     SFU at every size. No mesh.
   - One admitted connection per user per call, unchanged from ADR-0073.
   - Audio only until a reviewed, versioned `call.direct.signal.v2` grammar
     admits at most one bitrate-capped, non-simulcast video section.
   - Screen share, recording, whiteboards, chat, files, and readiness
     qualification stay on their existing paths.
6. **Outcome telemetry is counters only.** The peer link emits through
   `CommsObservability.Metrics.record/2` and renders on `/metrics` with a
   closed label set: attempts, connections by selected candidate class
   (`host`, `srflx`, `relay`), fallbacks by reason class (`ice_timeout`,
   `signaling`, `declined`, `ineligible`, `duplicate_connection`,
   `moderation`), and time-to-connect buckets. No user, tenant, call, address,
   SDP, or free-text label is admitted, so cardinality is fixed at compile time
   and the counters cannot become an identity store.
7. **Relay admission carries its own quota.** A `direct_audio_relay` scope
   joins the existing join and signal scopes in `PlatformRateLimits`, bounding
   credential mints per user per window independently of signal volume. A
   self-hosted relay additionally sets per-user and total allocation quotas and
   denies loopback, link-local, multicast, and RFC1918 peer ranges, so an
   allocation cannot be used to pivot into the host network.
8. **The kill switch stays one variable per rung.** `DIRECT_AUDIO_P2P_ENABLED`
   continues to disable the peer link entirely; a new
   `DIRECT_AUDIO_RELAY_ENABLED` disables only the relay rung, returning the
   system to ADR-0072 behaviour without a deploy.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Decision |
|---|---|---|---|
| Relay-only ICE restart after STUN failure | No relay allocation for links that never need one | Adds a second negotiation state and seconds of setup latency on exactly the worst networks | Deferred until allocation load is measured |
| Reuse LiveKit's embedded or managed TURN for the peer link | No new provider or credential | Those credentials are minted inside the SFU session for LiveKit's own peer connection; consuming them couples the peer link to SFU internals and an undocumented client surface | Rejected |
| Publish self-hosted coturn from the residential edge now | Full control, no provider dependency | Reopens the public routing, address stability, certificate, and abuse-control burden ADR-0057 deliberately closed | Rejected for the pilot |
| Three-party audio mesh | Keeps small groups off the SFU | Uplink and CPU grow with the square of participants, and mute, removal, and eviction guarantees would need per-peer enforcement | Rejected |
| Keep STUN only and let restrictive networks fall back | No change | The pilot's target networks are the failing ones, and each fallback spends the metered SFU bandwidth the peer link exists to save | Rejected |
| Persist per-call transport outcomes | Best forensic reconstruction | Recreates the address and identity store ADR-0071 and ADR-0072 refused | Rejected; counters only |

## Consequences

### Positive

- Endpoints behind symmetric NAT or UDP-blocking firewalls get a direct link
  instead of an SFU fallback, and media stays encrypted end to end because a
  relay forwards without terminating DTLS-SRTP.
- The relay rung is an ICE server list change, not a protocol change, so
  ADR-0073's state machine, grammar, quotas, and bounds are untouched.
- ADR-0072's own revisit trigger becomes measurable, and the fallback ratio
  becomes an alertable signal rather than a support anecdote.
- Participants who want address privacy get a mode that is better than plain
  peer-to-peer on disclosure and better than the SFU on media confidentiality.

### Negative and accepted trade-offs

- Relay candidates are gathered on every attempt, including the majority that
  never need them, so the relay sees allocations it never carries traffic for.
- A relayed audio link costs roughly two 50 kbit/s streams of relay bandwidth
  per call. That is negligible for audio and is precisely why this decision
  does not extend to video: the same ladder for video would move a
  megabit-class stream onto the same path.
- Relay-only mode adds a hop, and can be slower than the SFU path when the
  relay is far from both endpoints.
- A hosted relay adds a provider and a credential to the runtime configuration,
  which ADR-0072 avoided.

### Operational consequences

- One new secret and one new endpoint enter `runtime.env`, with the same
  never-in-Git handling as the existing LiveKit credential.
- `/metrics` gains a closed set of peer-link counters; `ops/alerts` gains a
  fallback-ratio warning that fires when the peer link stops working, before
  anyone reports poor audio.
- Rollback is a flag flip, not a deploy.

### Security and privacy consequences

- Relay credentials are short-lived, call-scoped, and opaque; a leaked one
  expires with the call and identifies no participant.
- A relay operator sees ciphertext and connection metadata and never holds
  media keys. The SFU provider, by contrast, holds decrypted media. Moving
  restrictive-network calls from SFU fallback to relayed peer link reduces the
  plaintext exposure surface.
- Address disclosure to the peer remains the accepted trade-off of the default
  mode, and is why relay-only mode exists.
- Nothing here changes the UAE regulatory position or the physical-office
  qualification gate.

## Validation

- Unit tests prove `ice_servers/1` shape, TTL ceiling, digest opacity, absence
  of relay credentials from logs, audit records, and peer broadcasts, and the
  empty-list result when the relay rung is disabled.
- Channel tests prove that a relay entry reaches only an authorized admitted
  participant, that the `direct_audio_relay` quota rejects mint floods, and
  that ADR-0073 negotiation, target isolation, and fallback behaviour is
  unchanged.
- Client tests prove relay-only policy produces relay candidates, that fallback
  remains terminal, and that the two prejoin modes carry distinct consent text.
- Metrics tests prove the rendered names, the closed label set, and that no
  identifier can reach a label.
- Browser validation exercises two endpoints on a network pair that fails
  STUN-only, and proves a `Direct` state over a relay candidate alongside the
  unchanged `LiveKit fallback`.
- The physical UAE office endpoint run, capacity evidence, and provider
  approval remain separate gates.

## Revisit triggers

- Measured relay allocation or bandwidth becomes material, which promotes the
  deferred relay-only ICE restart.
- Peer-link success on the default rungs rises to where the relay rung no
  longer earns its provider dependency, which retires it.
- Direct video, multi-device direct calls, or a small-group mesh becomes a
  product requirement, each of which needs its own reviewed grammar and budget.
- A datacenter or office edge appears, which changes the relay provider
  recommendation to self-hosted coturn.
