# ADR-0007: React and TypeScript reference web client

- **Status:** Accepted for MVP
- **Date:** 2026-07-12
- **Owners:** Architecture and product

## Context

The platform needs an independently evolvable reference client and a concrete test of REST, WebSocket, reconnect, replay, and attachment contracts.

## Decision

Use React, TypeScript, Vite, and the Phoenix JavaScript client. The production build is served from the Phoenix release; local development uses a separate Vite service.

## Consequences

API contracts remain client-neutral while the web experience can evolve independently. Node tooling is added to CI and the OCI image build.
