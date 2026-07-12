# Infrastructure

These Terraform modules are provider-neutral contracts. Select a cloud/runtime
through an ADR, then implement modules behind these interfaces and prove them in
staging before production use.

The hardened application-side composition is executable independently of that
provider selection under `deploy/k8s/overlays/production`. It consumes managed
database, object-storage, secret, DNS/certificate, and telemetry outputs; it
does not pretend that the contract-only Terraform modules provision them.
