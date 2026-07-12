# TLS, PKI, and Certificate Lifecycle

## MVP trust model

- Public HTTPS and WSS terminate at the Kubernetes ingress.
- The application container listens on private HTTP inside the pod network.
- PostgreSQL and object-storage TLS are enabled when the selected services expose trusted certificates.
- No production private key or certificate is committed to Git.

## Kubernetes-neutral implementation

The base manifests reference `k-comms-tls` and `k-comms-objects-tls`. A cluster
operator must provision those secrets with cert-manager, an ingress-controller
integration, or an external secret synchronization system. The example issuer
under `deploy/k8s/addons/cert-manager/` is not applied by the base overlay.

## Inventory

| Credential | Owner | Storage | Rotation |
|---|---|---|---|
| Public API/WSS TLS | Platform | Kubernetes TLS secret or ingress integration | Automated before expiry |
| Object endpoint TLS | Platform | Kubernetes TLS secret or ingress integration | Automated before expiry |
| Phoenix secret key base | Platform | External secret manager | Scheduled and incident-driven |
| Erlang distribution cookie | Platform | External secret manager | Maintenance window with rolling replacement |
| S3 access keys | Platform | External secret manager | At least quarterly and on compromise |
| Webhook signing secrets | Tenant/integration | Encrypted database field or secret manager | Tenant controlled |

## Controls

- Alert at 30, 14, and 7 days before certificate expiry.
- Exercise renewal and ingress reload in staging.
- Restrict read access to private keys and record access events.
- Revoke or replace compromised credentials immediately.
- Maintain overlapping trust during CA and signing-key rotation.
- Scan commits and OCI layers for PEM private-key markers.
