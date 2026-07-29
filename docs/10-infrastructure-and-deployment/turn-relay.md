# TURN relay for calls

## Why a relay is required

WebRTC prefers a direct peer path and falls back to a relay when it cannot get
one. Two common conditions remove the direct path entirely:

- **Symmetric NAT.** The address/port a peer learns through STUN is not the one
  the remote peer can reach, so candidate pairs never succeed.
- **UDP egress blocked.** Many corporate and guest networks permit only TCP 443
  outbound. RTP over UDP never leaves the network.

Under either condition a call does not degrade to lower quality. It fails: ICE
finds no working candidate pair and media never flows. A relay reachable over
TLS on 443 is what keeps those participants in the call.

This is why the same-host Compose proof and Kubernetes local-proof overlays are
explicitly not evidence that calls work for real users. They exercise only the
direct path on a permissive network.

## What this repository provides

Application-side plumbing only:

- `STUN_URLS` and `TURN_URLS` (comma-separated) configure the ICE servers.
- `TURN_STATIC_AUTH_SECRET` is the relay's shared secret. Setting `TURN_URLS`
  without it fails startup.
- `TURN_CREDENTIAL_TTL_SECONDS` bounds a derived credential's life
  (60–86400, default 3600).
- Each participant credential carries a per-participant ICE server list, and
  the browser passes it to the media session as `rtcConfig.iceServers`.

Credentials use the coturn REST scheme (`use-auth-secret`): the username is
`<expiry-unix>:<participant-identity>` and the password is
`base64(HMAC-SHA1(secret, username))`. The browser never receives the shared
secret, and a leaked credential expires on its own. The SHA-1 here is a keyed
MAC fixed by the TURN protocol, not a collision-sensitive digest.

`TURN_URLS` must use `turns:` in any promoted environment. Plaintext `turn:`
carries the derived credential in the clear and is the first thing a
restrictive network blocks; it is accepted only behind the local-development
adapter gate. `stun:` is permitted unencrypted because it carries no
credential.

A relay that is configured but invalid fails credential issuance rather than
silently issuing one without a relay. A silent fallback would drop exactly the
restricted-network participants the relay exists to serve, and would do so
invisibly.

## What this repository does not provide

**No TURN server is deployed here.** The portable base, staging, and production
overlays deliberately carry no SFU or TURN workload, and that has not changed.
Provisioning is a separate, reviewed deployment action covering at minimum:

- A coturn (or equivalent) deployment with `use-auth-secret` and a
  `static-auth-secret` matching `TURN_STATIC_AUTH_SECRET`.
- A TLS certificate and `turns:` listener on 443, so the relay survives
  networks that permit only HTTPS egress.
- Firewall and routing for the relay's TCP/UDP ranges.
- Capacity planning: relayed media consumes server bandwidth for every
  participant that cannot connect directly, unlike the direct path.
- Regional placement, because relay round-trip directly adds call latency.

## Verifying it works

Standard HTTP ingress checks prove nothing about relay reachability. A relay is
qualified only by observing a call succeed with the direct path removed:

1. Configure `TURN_URLS`/`TURN_STATIC_AUTH_SECRET` and restart the application.
2. Join a two-party call from a network that blocks UDP egress, or force relay
   mode in the browser, and confirm media flows both ways.
3. Confirm the selected candidate pair is of type `relay` in the browser's
   WebRTC internals, not `host` or `srflx`. A call that succeeds over a direct
   path proves the relay was not exercised.

Until step 3 has been observed, treat the relay as unproven regardless of
configuration.
