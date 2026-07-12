# OTP Design Guidelines

- Supervise processes according to failure and restart dependencies.
- Keep process state small, bounded, and reconstructable unless explicitly durable elsewhere.
- Avoid a single globally registered process for message ordering or tenant coordination.
- Use `DynamicSupervisor`, registries, or partitioned supervisors only when process ownership provides a concrete benefit.
- Define mailbox-growth and overload behavior for high-volume processes.
- Use call timeouts and failure-aware APIs.
- Prefer letting a supervised process fail on an unexpected invariant over silently corrupting state, while isolating the failure domain.
- Treat distributed node connectivity as an optimization path, not the durable consistency mechanism.
