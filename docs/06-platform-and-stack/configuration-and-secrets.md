# Configuration and Secrets

- Build artifacts are environment-neutral.
- Runtime configuration is injected through controlled configuration and secret systems.
- Secrets never enter source control, container images, logs, or client-visible configuration.
- Rotation is supported without full application rebuild.
- Configuration changes are reviewed, versioned, and auditable.
- Startup validates required configuration and fails clearly on unsafe combinations.
