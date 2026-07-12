# ADR-0009: Defer voice and video from the MVP

- **Status:** Accepted for MVP
- **Date:** 2026-07-12
- **Owners:** Architecture and product

## Context

A WebRTC media plane introduces TURN, SFU, regional media routing, recording, quality telemetry, and substantially different capacity and privacy requirements.

## Decision

The MVP implements text messaging, presence, files, search, notifications interfaces, and APIs. Voice/video is deferred to a later phase and will use a separate media plane.

## Consequences

The initial platform can reach a stable production shape sooner. Signaling namespaces remain reservable, but no media capability is promised by the MVP.
