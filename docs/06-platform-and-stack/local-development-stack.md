# Local Development Stack

Minimum local dependencies:

- Supported Erlang/OTP and Elixir toolchains
- PostgreSQL
- S3-compatible local object storage or a deterministic adapter
- Optional local mail/push/webhook capture services
- Telemetry collector when tracing changes

Use containerized dependencies for reproducibility while running the Elixir application natively when fast feedback is preferred. Seed scripts must create deterministic tenants, users, conversations, and message history.
