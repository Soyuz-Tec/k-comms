# Configuration and Secrets

- Build artifacts are environment-neutral.
- Runtime configuration is injected through controlled configuration and secret systems.
- Secrets never enter source control, container images, logs, or client-visible configuration.
- Rotation is supported without full application rebuild.
- Configuration changes are reviewed, versioned, and auditable.
- Startup validates required configuration and fails clearly on unsafe combinations.

For staging, `k-comms-secrets` has a stable name because Kustomize generator
hashing is disabled. Secret updates therefore require an explicit rollout
restart of edge and worker deployments and a new reviewed rendered bundle.
Database and object-storage credential rotation must be coordinated with those
services before their consumers restart.

The initial staging owner uses a separate `k-comms-bootstrap` Secret. It is
referenced only by the one-time release Job and is deleted, along with its local
env file, after success or failure. `ALLOW_BOOTSTRAP` remains `false`; the
staging HTTP API is not an administrative bootstrap path.
