# Authentication and Authorization

## Authentication

- Access tokens are short-lived and audience-bound.
- Refresh tokens are rotated and revocable per device/session.
- Sensitive administration can require step-up authentication.
- Service accounts and bots use separate credentials and scopes.

## Authorization

Every command evaluates:

- Tenant state
- Actor and session state
- Resource membership or role
- Operation-specific policy
- Content or attachment constraints
- Administrative overrides and audit requirements

A socket join authorizes subscription at that moment; it does not permanently authorize every later command.
