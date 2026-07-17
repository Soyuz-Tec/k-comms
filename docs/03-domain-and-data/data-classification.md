# Data Classification

| Class | Examples | Handling baseline |
|---|---|---|
| Public | Published documentation, public channel metadata when configured | Standard integrity controls |
| Internal | Service configuration, non-sensitive telemetry | Access-controlled; no public exposure |
| Confidential | User profiles, memberships, message metadata, call lifecycle/media kind, opaque participant admission identities and authorization bindings | Encryption, least privilege, audit; exclude provider identities from ordinary logs and support views |
| Restricted | Message bodies, private attachments, auth tokens including transient call participant JWTs, key material, live audio, camera video, and screen-share content | Strong encryption, redaction, short access paths, enhanced audit; never persist participant JWTs, frames, or screen media in the baseline |

## Rules

- Camera and screen content remain Restricted even when transported only
  ephemerally. A lack of K-Comms persistence does not reduce consent,
  incident-response, or provider-handling obligations.
- Call lifecycle, media kind, and opaque admissions are supportable metadata;
  room names, participant identities, tokens, device labels, and media quality
  labels that could identify a caller are excluded from ordinary telemetry.

- Logs and traces use allow-listed fields and exclude restricted content by default.
- Backups inherit the highest classification of contained data.
- Non-production environments must use synthetic or properly de-identified data.
- Data exports and support access are audited and time-bounded.
