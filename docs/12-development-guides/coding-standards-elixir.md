# Elixir Coding Standards

- Format all code with the repository formatter.
- Keep public functions small, typed with specifications where valuable, and documented when part of an internal/public contract.
- Use pattern matching deliberately; return stable tagged tuples at boundaries.
- Avoid exceptions for expected business outcomes.
- Make tenant and actor context explicit in application commands.
- Keep database transactions in application services, not controllers or channel handlers.
- Do not create atoms from untrusted input.
- Bound collection sizes, timeouts, retries, and process mailboxes.
- Prefer deterministic pure functions for domain state transitions.
- Log structured safe metadata; never interpolate raw message content or tokens.
