# Contracts

`openapi/` describes HTTP resources, `asyncapi/` describes real-time events, and
`json-schema/` contains independently testable payload schemas. Contract changes
require compatibility review and matching implementation/tests.

`python scripts/validate_contracts.py` performs JSON Schema meta-validation,
OpenAPI 3.1 validation, AsyncAPI structure/reference checks, and verifies that
the documentation mirrors match the canonical files byte-for-byte.
