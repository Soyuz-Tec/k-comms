# Developer Security Checklist

This is a per-change review template, not the current release-status record.
Release control status is maintained in
`docs/09-security-and-compliance/security-control-matrix.md`.

- [ ] Tenant and actor context are explicit.
- [ ] Authorization is evaluated for every operation.
- [ ] Inputs, payload size, and enum values are validated.
- [ ] No secrets or message bodies enter logs/traces.
- [ ] External URLs and callbacks are SSRF-safe.
- [ ] Retries and duplicate requests are safe.
- [ ] File paths, MIME types, and downloads are policy-controlled.
- [ ] New dependencies pass license and security review.
- [ ] Threat model and control matrix are updated for changed boundaries.
