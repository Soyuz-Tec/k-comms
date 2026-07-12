# Document Control

**Status:** Draft
**Owner:** Architecture Lead
**Reviewers:** Product, Security, SRE, Data, Engineering Management

## Metadata block

Use this block near the top of material documents:

```yaml
status: draft
owner: role-or-team
reviewers: [role-a, role-b]
last_reviewed: YYYY-MM-DD
next_review: YYYY-MM-DD
related_requirements: []
related_adrs: []
related_tests: []
```

## Status meanings

| Status | Meaning |
|---|---|
| Draft | Work in progress; not an implementation commitment |
| In Review | Complete enough for formal review |
| Approved | Accepted baseline for implementation |
| Superseded | Replaced by a newer named artifact |
| Retired | No longer applicable and retained for history |

## Review cadence

- Architecture and interface documents: on material change and at least quarterly during active delivery.
- Security and recovery documents: quarterly and after incidents.
- Runbooks: after every invocation and at least semiannually.
- Cost and capacity models: monthly during launch preparation, then quarterly.
