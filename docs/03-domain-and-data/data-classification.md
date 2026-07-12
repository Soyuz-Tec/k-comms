# Data Classification

| Class | Examples | Handling baseline |
|---|---|---|
| Public | Published documentation, public channel metadata when configured | Standard integrity controls |
| Internal | Service configuration, non-sensitive telemetry | Access-controlled; no public exposure |
| Confidential | User profiles, memberships, message metadata | Encryption, least privilege, audit |
| Restricted | Message bodies, private attachments, auth tokens, key material | Strong encryption, redaction, short access paths, enhanced audit |

## Rules

- Logs and traces use allow-listed fields and exclude restricted content by default.
- Backups inherit the highest classification of contained data.
- Non-production environments must use synthetic or properly de-identified data.
- Data exports and support access are audited and time-bounded.
