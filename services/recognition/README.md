# Bounded post-recording CPU recognition

This is an actual Whisper-compatible producer attached to the existing Calls
verified recording adapter. It is a source candidate, disabled by default. No
model installation, actual inference, server transport or provider qualification
was executed during source integration. It produces saved post-recording
English transcripts only. Live captions still require actual LiveKit transcription events.

Use Python 3.12+ on Linux in a separately isolated CPU service. Install the pinned
requirements after dependency/security qualification. Dependency resolution must
be retained as an immutable lock/SBOM before publication; this source requirements
file pins direct engines but does not claim a qualified transitive environment.
The MIT tiny.en snapshot and every model artifact are pinned in
`model-manifest.json`. `provision.py` is an explicit operator action and verifies
all SHA-256 values and sizes. The 75 MB model has not been fetched by this change.
The JFK fixture manifest identifies a public-domain US federal government speech
recording distributed with OpenAI's MIT Whisper test suite. Its source bytes were
hashed in memory; neither the fixture nor a model is committed.

After a CPU grant, provision and qualify the actual waveform independently:

```sh
python -m venv .recognition-venv
.recognition-venv/bin/pip install -r services/recognition/requirements.txt
.recognition-venv/bin/python services/recognition/provision.py --model-dir /tmp/kcomms-tiny-en --fixture /tmp/kcomms-jfk.flac
.recognition-venv/bin/python services/recognition/qualify_waveform.py --model-dir /tmp/kcomms-tiny-en --fixture /tmp/kcomms-jfk.flac
```

The last command executes actual waveform decoding and faster-whisper inference,
requires the expected spoken phrase, and emits only digest/mode/count evidence.
Protocol mocks do not establish waveform qualification.

Run the service with an operator-managed secret (32–4096 non-whitespace bytes),
`RECOGNITION_MODEL_DIR`, and `RECOGNITION_CPU_THREADS=1` (maximum 4). Start exactly
one Uvicorn worker, e.g. `uvicorn server:app --app-dir services/recognition
--host 127.0.0.1 --port 8080 --workers 1 --limit-concurrency 2
--timeout-keep-alive 5 --no-access-log`. Place an authorized fixed DNS HTTPS/443
reverse proxy in front, with header/upload/deadline limits and no request/body
logging. Do not expose the unauthenticated loopback transport directly. The Calls
adapter uses its existing pinned destination policy, rejects redirects and does
not admit an arbitrary URL. Network/TLS/origin/proxy behavior remains unqualified.
No generic provider proxy, live upload route, tools or remote model code exists.

Only authenticated `POST /v1/audio/transcriptions` is admitted. Uploads are at
most 26,214,400 bytes, decoded audio at most 300 seconds, output at most 1 MiB /
10,000 ordered segments. A single inference slot refuses excess work. Entire
model verification/load, decode and inference is in a killable child, with 55s
wall/CPU bounds. Temporary media and output are deleted after success, failure or
cancellation. HF network and telemetry are disabled. Mount the separately provisioned model directory read-only. Restrict the process/container
filesystem, outbound network, CPU and memory at deployment; exact service resource
and interruption qualification is pending.

Set Calls runtime `ARTIFACT_TRANSCRIPTION_ORIGIN` to the actual authorized HTTPS
origin, `ARTIFACT_TRANSCRIPTION_MODEL=tiny.en`, protected
`ARTIFACT_TRANSCRIPTION_BEARER_TOKEN`, and
`ARTIFACT_TRANSCRIPTION_MODEL_SHA256=1a5afae06a4db91c975c9a9d78be5cc110ee4ea022ad57d55492e4550e936b2a`.
Explicit `ARTIFACT_TRANSCRIPTION_ENABLED=true` and
`ARTIFACT_TRANSCRIPTION_QUALIFIED=true` also require existing approved tenant,
privacy, verified storage and LiveKit policy. Never set qualified based on source
parsing or mock responses.

Summaries use the actual bounded local `extractive-quotes-v1` adapter in the
application, without an LLM or external HTTP effect. Separately enable
`MEETING_SUMMARY_PRIVACY_APPROVED`, `ARTIFACT_SUMMARIES_ENABLED` and
`ARTIFACT_SUMMARIES_QUALIFIED` only after owner/privacy/browser qualification.
Host disclosure and every admission's explicit summary decision are still needed.
All these defaults are false.
