# ADR-0008: Podman local workflow and Kubernetes-neutral deployment

- **Status:** Accepted for MVP
- **Date:** 2026-07-12
- **Owners:** Architecture and product

## Context

The deployment must avoid coupling to a particular cloud provider while remaining reproducible for developers and staging.

## Decision

Use OCI images built with Podman, Compose-compatible local services, standard Kubernetes APIs, and Kustomize overlays. The staging overlay includes PostgreSQL and MinIO for portability; production replaces stateful services through a provider-specific overlay.

## Consequences

Developers can use Podman without Docker. Cluster-specific ingress, storage classes, certificate controllers, and managed services remain deployment inputs rather than application assumptions.
