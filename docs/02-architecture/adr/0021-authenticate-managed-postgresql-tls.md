# ADR-0021: Authenticate managed PostgreSQL TLS

**Status:** Accepted

## Context

The production runtime previously enabled PostgreSQL TLS with a Boolean switch.
That encrypted the transport but did not give the application an explicit,
auditable trust bundle and verification hostname. A provider or network
misconfiguration could therefore weaken the intended database identity
boundary without changing the retained application bundle.

Production uses a managed PostgreSQL endpoint, and its CA and certificate DNS
name are provider-composition inputs. Development and portable staging use a
local database without TLS.

## Decision

When `DATABASE_SSL=true`, runtime configuration will require both:

- `DATABASE_SSL_CA_FILE`, a readable mounted PEM bundle containing at least one
  valid certificate; and
- `DATABASE_SSL_SERVER_NAME`, an explicit DNS hostname covered by the managed
  PostgreSQL server certificate.

The PostgreSQL client will use `verify_peer`, the mounted CA bundle, explicit
TLS server-name indication, and OTP hostname verification. Missing, malformed,
ambiguous, or IP-literal inputs stop the release before it connects. The CA is
public trust material and is mounted from the provider-composed
`k-comms-database-ca` ConfigMap rather than copied into an image or credential
Secret. Database credentials remain only in `DATABASE_URL` in the externally
managed runtime Secret.

When `DATABASE_SSL=false` (the local and portable staging contract), no CA or
hostname input is required and existing non-TLS behavior is preserved.

## Consequences

- A production edge, worker, migration, or other release command cannot use a
  TLS database connection unless it can authenticate both the issuing CA and
  certificate hostname.
- Provider composition must retain the exact CA ConfigMap, verification
  hostname, and mount in every workload that evaluates the release runtime
  configuration.
- CA rotation uses an overlap bundle containing old and new trust anchors,
  followed by a rollout and verified database reconnection, before the retired
  CA is removed.
- A database endpoint whose certificate exposes only an IP address is not a
  supported production composition; a provider DNS endpoint is required.

## Alternatives considered

- **Rely on encryption without peer verification:** rejected because it does
  not authenticate the database boundary.
- **Use the container operating-system trust store implicitly:** rejected
  because the selected managed/private CA would not be an explicit retained
  deployment input and rotation would be coupled to the image.
- **Put the CA PEM in the runtime Secret:** rejected because CA certificates
  are public trust material and should rotate independently from credentials.
- **Infer the verification name silently from arbitrary URL input:** rejected
  because provider aliases and certificate names must be reviewed explicitly.

## Validation

Unit tests cover the disabled path, verified TLS options, malformed CA files,
missing inputs, invalid hostnames, IP literals, and ambiguous Boolean values.
The rendered production bundle must retain the CA mount and exact verification
configuration; live promotion additionally proves a successful verified
connection and rehearses CA rotation.
