# Test Pyramid and Boundaries

Keep most business-rule tests below network adapters. Integration tests use a real PostgreSQL instance and exercise transaction, constraint, and concurrency behavior. End-to-end tests remain focused on critical journeys rather than duplicating every rule.

Mock external providers behind owned adapters; also run a smaller set of sandbox contract tests against real provider interfaces.
