# Workspace domain discovery

This opt-in flow supplies a workspace sign-in address after exact DNS ownership
verification. It does not prove a person's email or authorize membership, account
linking or an identity provider. Source integration is under review; migration,
runtime, browser and authorized real-DNS qualification remain pending.

Use **Workspace control center → Domains** as an active workspace-human owner
or administrator. Complete recent identity proof when prompted. Register an
exact ASCII domain you are authorized to control; emails, URLs, wildcards,
suffix matching and implicit subdomains are unavailable. Claims default to
discovery off. There is a hard limit of eight retained rows per tenant, including
expired and opted-out claims.

1. Create the claim and copy its private TXT name and value to the authorized
   DNS zone. The challenge lasts thirty minutes. Treat its value as private
   proof and keep it out of logs, screenshots and support tickets.
2. Wait for the intended resolver to serve the exact TXT value, then choose
   Verify. A successful fresh DNS check consumes the token and grants a lease
   lasting at most seven days. Failure or timeout preserves the previous lease
   and never extends proof. The resolver is bounded to five seconds; system DNS
   does not establish application DNSSEC verification.
3. Explicitly enable discovery. Public visitors submit only a domain and choose
   whether to use the returned relative workspace address. Unknown, expired,
   disabled and inactive claims share the same neutral HTTP200 response.
4. Before lease expiry, renew the challenge and verify the new TXT value. A new
   challenge preserves the old lease until its original expiry; it does not
   renew proof by itself. Remove obsolete TXT records after token consumption.
5. Disable discovery to stop hints while retaining the claim, or revoke to
   physically remove it and free capacity. On a version conflict, reload the
   inventory, review the changed version, and explicitly retry. Reload after an
   ambiguous write failure before issuing another mutation.

The private panel clears TXT/access state on current-authority loss and strips
challenge values before step-up. Governed user erasure removes pending and
expired personal challenges. A live verified tenant lease keeps its original
expiry, while the erased actor's renewal token and actor link are detached.
Completion evidence contains counts and domain_challenge_erasure_version=1 for
user targets; the registered historical reconciler repairs missing user proof
under the existing tenant and canonical writer fences. Other erasure scopes do
not claim a domain proof. Physical tenant deletion uses the existing FK cascade.

Before rollback, use the existing current-image database-quiesced preflight in
the [Kubernetes procedure](../../deploy/k8s/operations/guest-rollback-preflight/README.md)
or [Proxmox procedure](../../deploy/proxmox/README.md). Every retained claim
requires workspace_domain_discovery_v1, regardless of status, disclosure or
tenant eligibility. Turning discovery off or allowing a lease to expire does
not clear this hazard. No Discovery background worker exists. Preserve the exact
target-image capability receipt: M1 has twelve, Member/History fourteen, current
Discovery fifteen. An incomplete/invalid hazard snapshot must fail even if the
target declares every capability. Revoke all retained claims through their owner
or roll forward to a compatible image; never alter target capabilities locally
to bypass the guard. Fingerprint receipts expose only scalar counts and a hash.

Keep synthetic qualification separate from real DNS acceptance. Root must run
compiler and database tests, migration refusal/clean rollback drills, strict
architecture and source-derived contracts, UI/browser/accessibility and fresh
HTTP checks. An authorized domain and deployment resolver are required for real
ownership acceptance. Retain content-free receipts; protected production
approval remains independent.

See [the wire contract](../04-interfaces/workspace-domain-discovery.md) and
[ADR0097](../02-architecture/adr/0097-verify-opt-in-workspace-domain-discovery.md).
