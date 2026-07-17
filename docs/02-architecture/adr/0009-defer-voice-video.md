# ADR-0009: Defer voice and video from the MVP

- **Status:** Partially superseded by ADR-0024
- **Date:** 2026-07-12
- **Owners:** Architecture and product

## Context

A WebRTC media plane introduces TURN, SFU, regional media routing, recording, quality telemetry, and substantially different capacity and privacy requirements.

## Decision

The MVP implements text messaging, presence, files, search, notifications interfaces, and APIs. Voice/video is deferred to a later phase and will use a separate media plane.

ADR-0024 activated audio-only calls through that separate media-plane boundary;
ADR-0025 now activates the unified audio/video scope. SIP, recording,
transcription, and arbitrary media egress remain deferred.
Video, screen sharing, SIP, recording, transcription, and media egress remain
deferred by this decision.

## Consequences

The initial platform can reach a stable production shape sooner. Signaling namespaces remain reservable, but no media capability is promised by the MVP.

Audio activation does not imply that the production media provider, TURN/TLS,
regional capacity, privacy review, or operational readiness gates are closed.
