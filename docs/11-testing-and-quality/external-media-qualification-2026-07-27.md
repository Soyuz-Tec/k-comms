# Production external-media qualification — 2026-07-27

**Status:** Qualified for two-party cellular audio/video

**Environment:** Production

**Media topology:** Managed LiveKit Cloud

**Related decisions:** ADR-0025 and ADR-0057

## Scope

This record closes the production external-media qualification required by
ADR-0057: a two-party call with physical participants outside the local
network. It records the human-observed network condition separately from the
content-blind provider telemetry because the provider does not expose whether
an iPhone's Wi-Fi control was disabled.

This record does not claim completion of the broader group-capacity,
screen-share, forced TURN/TLS, privacy, provider-outage, secret-rotation, or
incident-response gates listed in ADR-0025.

## Human attestation

On 2026-07-28, the qualification owner confirmed that both physical iPhones
used for the recorded call had Wi-Fi disabled. The participants therefore
joined over independent cellular Internet access rather than the K-Comms host
LAN.

## Provider evidence

The protected `k-comms-production` LiveKit Cloud project retained session
`RM_qoW2DgxcwD9u` for room
`kc_call_3803189cd3fc4c9082f80aa8990edaef`.

The provider record shows:

- two unique physical iPhone participants in the same closed session from
  2026-07-27 16:20:47 through 16:24:10 as displayed by the dashboard;
- Chrome Mobile on iOS and Mobile Safari on iOS, both using LiveKit JS 2.20.1;
- UDP transport from the United States to the provider's Canada region, with
  connection times of 289 ms and 376 ms;
- a published microphone track from each participant using `audio/red`;
- a published camera track from each participant using VP8 simulcast layers
  at 320×180, 640×360, and 1280×720;
- successful subscriptions to the other participant's microphone and camera
  tracks;
- 106.32 MB total upstream and 74.01 MB total downstream during the session;
  and
- no recording or egress session.

The provider overview for the seven-day qualification window reported 100%
connection success and 100% UDP transport. The private provider record is:

`https://cloud.livekit.io/projects/p_6560u0j3jdt/sessions/RM_qoW2DgxcwD9u`

## Current production continuity

The subsequent protected production receipt for revision
`1ce13ca3aae2450b6d3bf64032204f1edaee7bc8` records:

- image
  `ghcr.io/soyuz-tec/k-comms@sha256:0da54ada659541bbf9ef101a912b3be9c80e1deede83303dceaa30fd7aa07eef`;
- `media_topology` set to `managed_cloud`;
- a complete pre-deployment backup; and
- successful public application, media, and object-storage verification.

At record time, production `/health/ready` and the managed media endpoint
returned HTTP 200. `/api/v1/status` reported `audio_calls`, `video_calls`, and
`secure_media_actions` as enabled.

Changes after the managed-cloud introduction did not replace the LiveKit
provider boundary. The current release retains the qualified topology and
provider integration.

## Result

The two-party physical cellular audio/video requirement in ADR-0057 passed.
The former outstanding external-media item is closed.

The following separate gates remain open:

- forced TURN/TLS and ICE/TCP fallback evidence;
- representative group size and bandwidth headroom;
- external screen-share publication and subscription;
- privacy/consent approval and recording-policy review;
- provider outage and recovery rehearsal;
- incident routing and secret-rotation evidence.
