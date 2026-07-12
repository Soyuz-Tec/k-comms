# Network Topology

## Zones

- Public ingress: CDN/WAF/load balancer only.
- Application: edge/API and worker runtimes with controlled egress.
- Data: PostgreSQL, search, cache if used, and telemetry backends.
- Management: CI/CD deploy identities, break-glass access, and observability administration.

## Rules

- Databases and internal services have no direct public ingress.
- Provider egress is allow-listed where practical.
- Webhook delivery has SSRF-resistant egress controls.
- Service identity and encryption are preferred over trust by subnet alone.
- Network-flow logs and rejected-connection metrics support incident investigation.
