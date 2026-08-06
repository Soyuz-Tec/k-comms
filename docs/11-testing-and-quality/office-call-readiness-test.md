# Office call readiness test

Use this test to determine whether one exact office network and device can hold
a real K-Comms audio conversation over the restricted TURN/TLS fallback path.
It does not approve the office, provider, or product for general production use.

## Preconditions

- Use the exact immutable release under qualification.
- The host is signed in and audio calling reports healthy.
- One participant is physically connected to the target UAE office network.
- Both participants have a working microphone and speaker and consent to a live
  conversation. K-Comms does not record the audio.

## Procedure

1. Open **Calls** and select **Create office test link**.
2. Send the generated one-use link to the office participant. It expires after
   ten minutes and is consumed by the first admitted guest.
3. Select **Open my test call**. The office participant opens the invite. Both
   sides leave **Run secure office network qualification** enabled and select
   **Run office call test**.
4. Wait for secure signaling, TURN relay, relay microphone publication,
   connection recovery, and TURN/TLS path checks to finish.
5. When the 60-second measurement starts, both participants speak naturally.
   Select **I can hear the office** only after hearing intelligible speech.
6. Download the privacy-safe JSON report on each endpoint. Do not substitute a
   screenshot of an intermediate state for the final report.

## Result interpretation

- **Ready:** all required transport/two-way-audio checks passed and quality was
  within the defined thresholds.
- **Ready with warnings:** the secure two-way path passed, but packet loss was
  above 3%, jitter above 50 ms, RTT above 400 ms, or the room reconnected.
- **Not ready:** a required preflight failed, TLS relay/TCP was not verified,
  inbound or outbound audio packets were absent, or audible speech was not
  confirmed.

The downloaded report excludes audio, participant and room identifiers,
credentials, SDP, candidate addresses, and raw browser statistics. Retain it
only under the release-evidence policy. A passing run closes evidence only for
the tested endpoints, office network, time, and immutable release; the capacity,
screen-share, privacy-approval, provider-outage, incident, and secret-rotation
gates remain separate.
