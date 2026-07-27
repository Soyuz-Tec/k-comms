# Development Environment

## Standard workspace

The standard development environment on the managed Windows workstation is:

`C:\Users\vasan\OneDrive\Documents\k-comms`

This local checkout is the default location for implementation, focused tests,
local runtime verification, and branch preparation. Supported Erlang/OTP,
Elixir, Node.js, PostgreSQL, and S3-compatible dependencies may run natively or
through Podman/Compose according to the repository development guides.

Development uses synthetic data and development-only secrets. Production data,
production credentials, production volume copies, and deployment tokens do not
belong in this workspace.

There is no separate Proxmox development VM. The Proxmox environments are:

- VM 101 at `192.168.1.23`: protected staging with synthetic data.
- VM 100 at `192.168.1.22`: production with authoritative data.

`deploy/proxmox/inventory.json` is authoritative for those VM assignments.

## Worktree policy

Temporary registered Git worktrees may be used to isolate pull requests,
release operations, or recovery work from an active dirty checkout. They are
not additional development environments.

Before removing a temporary worktree:

1. Confirm its absolute path is inside the intended workspace root.
2. Inspect tracked and untracked status.
3. Prove unique commits are merged or retained on a remote branch.
4. Preserve any unique design artifact or uncommitted change in the canonical
   workspace or an approved remote branch.
5. Remove the worktree through `git worktree remove`.
6. Prune only stale metadata whose referenced directory no longer exists.

Do not create independent duplicate clones to work around a dirty checkout.
Create a registered worktree from the canonical repository instead.

## Readiness checklist

- [x] Canonical Windows workspace identified
- [x] GitHub remote and protected `main` are authoritative
- [x] Local data policy is synthetic-only
- [x] Staging and production are excluded from development use
- [x] Temporary-worktree cleanup policy documented
- [ ] Active branch and local runtime verified at the start of each task
- [ ] Synthetic message workflow passes for the current change
