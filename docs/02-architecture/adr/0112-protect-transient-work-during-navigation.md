# ADR-0112: Protect transient work during navigation

- **Status:** Accepted
- **Date:** 2026-10-06
- **Owner:** Web application
- **Related decisions:** ADR-0101, ADR-0104

## Decision

Use React Router's supported data-router blocker for unfinished shared-document
edits and private-room work. The browser data router wraps the existing route
tree; public/member paths, query parameters, fragments, authentication return
state and desktop history controls retain their existing contracts. The entry
point creates one router outside React StrictMode. Isolated App owners dispose
their router when unmounted.

A single application blocker collects predicates and generic descriptions from
mounted feature owners. It stores no draft text, document content, credentials,
recovery keys or encrypted messages. The existing shared confirmation dialog
provides keyboard access, focus containment, **Stay here** and explicit **Leave
and discard** actions. Links, programmatic navigation and browser Back/Forward
use the same decision. Fragment-only moves within the same resource are safe.
Browser close/reload continues to use `beforeunload`.

Unsent text and uncertain command receipts remain only in their existing memory
owners. Staying leaves those owners mounted. Leaving unmounts them. A private-room
owner also resets and locks its component on explicit discard, including
query-only history that would otherwise keep the component mounted. Clean room
history selects the requested room under current authority without pushing a
replacement history entry. A server may
still complete an already submitted operation; the confirmation explicitly
explains that discard does not cancel server work. Document retries retain their
original IDs and inputs. Private-room exact encrypted retry semantics and crypto
protocol are unchanged. Locking a private device also confirms before clearing
an unsent draft or recovery material.

The blocker is scoped to current credentials, workspace, user, device and
permission/version facts. Authority withdrawal, logout or identity changes must
clear old local work and never be intercepted by an old draft guard. No plaintext
persistence or cross-identity draft recovery is introduced. The private-room
component now remounts on these authority changes, as shared documents already
do. Local crypto authority withdrawal still clears plaintext immediately.

Private-room device setup requires an explicitly enabled service capability,
current room-list access, an online browser, HTTPS and Web Locks. Unknown or
failed capability reads fail closed and offer retry. The service capability is
configuration preflight, not live provider health or a claim of crypto
qualification. Actual unlock still exercises server and native crypto authority.

## Evidence and limits

Regression tests reproduce the previous in-app navigation loss, exercise the
real document synchronization hook and maintained editor, and cover cancelled
and confirmed navigation, native history, authority changes, page unload and
availability retry. Browser tests exercise the rendered application and native
Back/Forward with synthetic API/socket responses. These tests do not qualify a
live Matrix provider, multi-device crypto, carrier, staging or production.
