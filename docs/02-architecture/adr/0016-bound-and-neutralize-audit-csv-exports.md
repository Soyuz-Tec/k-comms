# ADR-0016: Bound and neutralize audit CSV exports

- **Status:** Accepted
- **Date:** 2026-07-12
- **Owners:** Architecture, security, compliance, and tenant administration
- **Related requirements:** NFR-AUD-001, NFR-SEC-001, NFR-TEN-001, NFR-API-001

## Context

Compliance administrators need portable tenant audit evidence. Exporting only
the rows already loaded by the browser would be incomplete, while an unbounded
database export could exhaust application resources. Audit values are also
untrusted spreadsheet input: a cell beginning with a formula character can
execute when an operator opens the file in common spreadsheet software.

## Decision

K-Comms exposes a dedicated step-up-authenticated tenant administration export
command. The server applies tenant scope and validated action, resource, actor,
request, time-window, and bounded free-text filters before sorting and limiting
the result. Exports default to 1,000 records and are capped at 5,000. The
response is an attachment with explicit row-count and truncation headers so the
client can tell an administrator to narrow the filter.

The server generates the CSV. Every cell is quoted, embedded quotes are
escaped, NUL bytes are removed, and values with optional leading whitespace
followed by `=`, `+`, `-`, `@`, tab, or carriage return receive a leading
apostrophe. Successful generation and its `audit.export` evidence record occur
in one database transaction. Evidence records the structured filters, returned
count, configured maximum, and truncation state, but records only the presence
of a free-text query rather than its potentially sensitive contents.

The web client uses the authenticated response body and a conservative CSV
filename allowlist. It does not serialize the visible HTML table.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Rejection reason |
|---|---|---|---|
| Export the loaded browser page | Minimal backend work | Partial and client-tamperable evidence | Cannot provide authoritative evidence |
| Unbounded synchronous export | Simple user model | Memory, query, and denial-of-service risk | Violates bounded-work requirements |
| Asynchronous object-storage export | Scales to much larger datasets | Adds job, encrypted object, expiry, and notification lifecycle | Defer until exports must exceed the MVP cap |
| Escape only commas and quotes | Conventional CSV formatting | Leaves spreadsheet formula injection possible | Unsafe for an administrative evidence workflow |

## Consequences

### Positive

- Exported rows are authoritative, tenant-scoped, and independently audited.
- Resource consumption has a deterministic upper bound.
- Spreadsheet formula injection is neutralized centrally.
- Truncation is visible to both the API client and the audit ledger.

### Negative and accepted trade-offs

- Administrators must refine filters when more than 5,000 rows match.
- Formula-looking values display with a leading apostrophe in spreadsheet
  software.
- Large asynchronous export remains future work.

## Validation

- Cross-tenant records are absent after filtering and capping.
- Step-up is required and malformed actor/time/filter shapes are rejected.
- Formula prefixes, quotes, NUL removal, count, truncation, and disposition are
  covered by core and controller tests.
- The web client sends the visible filter, performs an authenticated download,
  accepts only a safe CSV filename, and announces truncation accessibly.

## Revisit triggers

- Tenants require exports larger than 5,000 rows or recurring exports.
- Evidence packages require signing, encryption, manifests, or object-storage
  retention.
