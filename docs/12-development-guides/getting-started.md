# Developer Getting Started

## Expected workflow

1. Install the repository-pinned Erlang/OTP and Elixir versions.
2. Start PostgreSQL and local object-storage dependencies.
3. Copy the safe example configuration; never copy real secrets.
4. Create and migrate the local database.
5. Load deterministic seed data.
6. Run formatting, static checks, unit tests, and integration tests.
7. Start the API/edge and worker roles.
8. Exercise the synthetic send and reconnect workflow.

The implementation repository should expose these actions through a small, documented command surface such as `make`, `just`, or Mix aliases.
