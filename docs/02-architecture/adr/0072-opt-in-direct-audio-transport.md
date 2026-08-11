# ADR-0072: Add an opt-in direct transport for one-to-one audio

- **Status:** Accepted for implementation
- **Date:** 2026-08-09
- **Owners:** Media, Web
- **Reviewers:** Architecture, Security, Release and Quality
- **Related requirements:** FR-COM-001, NFR-SEC-001, NFR-REL-001, ADR-0025, ADR-0057, ADR-0060, ADR-0067, ADR-0071

## Context

K-Comms already provides an installable PWA and an authorized LiveKit audio and
video media plane. A two-person call can often use a browser-to-browser WebRTC
path without placing audio on an SFU, reducing media-path latency and provider
bandwidth. It cannot do so reliably on every network: restrictive or symmetric
NATs may require a relay.

The initial direct path must add no new paid infrastructure. It must not weaken
the Calls lifecycle, membership, removal, expiry, or rolling-client
compatibility, and it must make the WebRTC address-disclosure consequence clear
to both people. Direct transport is not a way to bypass UAE regulation or the
separate physical-office qualification gate.

## Decision

K-Comms adds an optional, audio-only direct media path for active direct
conversations.

1. Both people explicitly select **Prefer a direct connection** in prejoin.
   The consent text says that WebRTC reveals each device's network address to
   the other participant. The preference is memory-only and resets after the
   call.
2. Both clients first join the normal LiveKit room and the authorized Phoenix
   call topic. LiveKit remains connected as the authoritative participant,
   revocation, expiry, and fallback path.
3. The call topic admits direct signaling only when the runtime feature flag is
   enabled, the conversation is direct, the call is active and audio-only, and
   the current session is an admitted participant. Every signal is
   re-authorized.
4. Phoenix Presence allocates an unpredictable per-connection peer ID. Direct
   media starts only while exactly one opted-in connection exists for each
   user and exactly one remote participant is in LiveKit. Any additional
   connection keeps or returns the call to LiveKit, preventing multi-device
   mesh formation and duplicate audio.
5. The call topic relays only targeted, allowlisted, size-bounded and
   rate-limited offer, answer, ICE-candidate, microphone-state, and fallback
   messages. Signaling is ephemeral and is not written to the database, audit
   log, outbox, or application logs. No data channel is enabled.
6. The initial ICE configuration uses the public Cloudflare STUN endpoint only.
   It requires no K-Comms credential or new paid service. If direct ICE or
   signaling fails, either client declines, a moderation event occurs, or a
   selected peer leaves, both clients use the already-connected LiveKit room.
7. After the direct peer connection succeeds, the client mutes its LiveKit
   microphone and publishes microphone audio only on the direct connection.
   The UI always identifies `LiveKit`, `Switching to direct`, `Direct`, or
   `LiveKit fallback`.
8. Video, group/channel calls, screen sharing, readiness qualification,
   recording, guest rooms, files, and chat remain on their existing paths.
   No end-to-end-encryption claim is added.

This decision narrowly supersedes ADR-0025's prohibition on exchanging SDP and
ICE through Phoenix and ADR-0057's rejection of peer-to-peer calls. The
exception is limited to transient, authorized one-to-one audio negotiation;
LiveKit remains the default and fallback media architecture.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Decision |
|---|---|---|---|
| Replace LiveKit with peer-to-peer calls | Removes the SFU from two-party media | Breaks group/video uniformity, reliable fallback, and server-enforced moderation | Rejected |
| Add a new TURN service now | Direct transport succeeds on more restrictive networks | Adds credentials, operations, and possible usage charges | Deferred; existing LiveKit is the relay fallback |
| Use WebRTC data channels for signaling or chat | Can reduce server messages after negotiation | Complicates authorization and duplicates existing Phoenix capabilities | Rejected |
| Default direct mode on without consent | Faster adoption | Hides IP-address disclosure and changes privacy expectations | Rejected |

## Consequences

### Positive

- Suitable one-to-one calls can use a shorter media path with no new service
  subscription or secret.
- Unsupported networks degrade to the already-qualified call service instead
  of failing the call.
- The installable PWA remains the single client; no app-store package or native
  signaling stack is required.

### Negative and accepted trade-offs

- STUN-only direct ICE does not work through every NAT or firewall.
- A direct peer learns address information that the SFU normally hides; this is
  why consent is explicit on both devices.
- LiveKit control connectivity is still required, so this is not an offline or
  serverless call architecture.
- The initial direct-path status is client-visible but not centrally retained.

## Security and privacy

- Peer IDs are random connection identifiers, not user, device, session, or
  provider identities.
- Target peers must be present on the same authorized call topic and belong to
  a different user.
- SDP is limited to 16 KiB, candidates to 2 KiB, and direct signals to 240 per
  minute per call session.
- A mute or removal event abandons direct media and returns to LiveKit, where
  media-plane enforcement remains authoritative.
- The feature can be disabled immediately with
  `DIRECT_AUDIO_P2P_ENABLED=false`.

## Validation

- Channel tests cover eligible two-party signaling, target isolation, payload
  bounds, and non-direct denial.
- Client tests cover deterministic negotiation, queued ICE, microphone control,
  explicit consent, and ineligible conversation UI.
- Browser validation must exercise two independent clients and prove both the
  `Direct` state and automatic `LiveKit fallback` state.
- Production evidence remains incomplete until the exact immutable release is
  tested between a physical UAE office endpoint and its counterpart.

## Revisit triggers

- Direct success rates justify a credentialed TURN service or a separately
  operated relay.
- Product requirements need direct video, group mesh, recording, or retained
  transport analytics.
- Browser privacy changes remove host-candidate address disclosure or alter the
  consent model.
