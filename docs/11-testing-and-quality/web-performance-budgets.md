# Web asset budgets and browser qualification

## Build gate

`clients/web/asset-budgets.json` defines raw and gzip byte ceilings for the shared
sign-in shell, inbox, files, whiteboard, inbox with an active call, and all emitted
JavaScript/CSS. `npm run build` generates the Vite manifest, finalizes the PWA,
and enforces these budgets. `npm run check:assets` repeats the check against an
existing build. `npm run test:assets` checks the gate's failure cases and runs as
part of `npm test` in CI.

The gate follows the manifest's static imports from each named route plus the
shared entry. Shared chunks, cycles, and CSS are counted once per route. Optional
dynamic imports are excluded from that route closure and included in the total
build ceiling. Missing route entries or dependencies fail, rather than silently
reporting a smaller route after a rename. Both compressed and uncompressed sizes
must pass. Gzip is calculated independently for each asset with Node's default
compression settings; it is a reproducible comparison, not an assertion about
the server's compression configuration.

Initial baseline, measured on 2026-09-19 from client recovery commit `c7bc4a0`
with the build manifest enabled:

| Static import closure | Raw bytes | Gzip bytes |
|---|---:|---:|
| Shared entry/sign-in | 2,074,316 | 583,964 |
| Inbox | 2,213,846 | 621,937 |
| Files | 2,098,038 | 590,262 |
| Whiteboard | 2,109,302 | 594,856 |
| Inbox with call panel | 2,819,592 | 779,259 |
| All emitted JS/CSS | 9,479,231 | 2,974,747 |

The initial ceilings allow roughly 8–10% reviewed growth rather than treating
the existing footprint as an ideal target. The active-call gate also includes
the inbox. Changes to ceilings need a measured before/after build and an
explanation in the PR. Do not auto-update them to make a failed build pass.
Avoid relying on Vite's individual 500 KB warning: it misses cumulative imports
and can be sidestepped by splitting the same payload into more files.

These measurements exclude images, fonts, API traffic, workers, and conditionally
requested dynamic chunks from each route. They do not measure actual cold network
transfer, parse/execute time, rendering, interaction latency, or memory. A small
route chunk can still import a large shared dependency set. The present shared
entry footprint deserves a separate profile before changing chunk boundaries.

## Reviewed interface increment (2026-10-05)

The interface refresh deliberately allocates 100,000 additional raw bytes to
all emitted JavaScript/CSS (10,300,000 → 10,400,000, +0.971%). All five named
route ceilings and the 3,250,000-byte aggregate gzip ceiling remain unchanged.
The aggregate assertion continues to include every emitted dynamic chunk; the
checker and its failure-case tests are unchanged.

The retained pre-change production build, whose web source is unchanged through
protected base `ad49eb6`, measured 10,296,074 raw / 3,128,288 gzip bytes. The first
refresh build measured 10,348,800 raw / 3,140,926 gzip bytes and correctly failed
the former raw ceiling by 48,800 bytes. The measured increment is 52,726 raw
(+0.512%) and 12,638 gzip (+0.404%): 31,696 bytes of JavaScript and 21,030 of CSS.

| Static import closure | Before raw / gzip | First refresh raw / gzip |
|---|---:|---:|
| Shared entry/sign-in | 2,147,515 / 603,123 | 2,156,760 / 605,011 |
| Inbox | 2,311,982 / 649,328 | 2,321,475 / 651,250 |
| Files | 2,180,027 / 611,245 | 2,190,265 / 613,525 |
| Whiteboard | 2,194,285 / 617,826 | 2,204,767 / 620,011 |
| Inbox with call panel | 2,937,402 / 814,210 | 2,950,759 / 816,928 |
| All emitted JS/CSS | 10,296,074 / 3,128,288 | 10,348,800 / 3,140,926 |

Independent review considered this bounded allocation appropriate for the
requested cross-page navigation, resource disclosures, recording library,
profile consolidation, recovery guidance, and consistent controls. There are no
new dependencies or lockfile changes. The shared entry grew by only 9,245 raw /
1,888 gzip bytes; the remainder is feature-local. Removing 48,800 bytes would
consume 92.6% of the measured requested increment, while a CSS cleanup large
enough to recover that space would require a separate cascade audit. This is a
specific reviewed UI allocation, not an automatic baseline update or a
responsiveness claim. The final official build must still pass every ceiling;
its exact measurements and verification belong in the pull request.

## Browser regression scope

CI installs Chromium and WebKit. The existing desktop WebKit matrix remains;
`mobile-webkit` adds iPhone 13 emulation for the bounded `client-recovery`,
`mobile-webkit`, and `whiteboard` specs. This covers accessible route recovery,
truthful draft persistence, paginated file categories, dialog focus, navigation,
whiteboard layout, and a real editor template operation that survives an offline
reload in IndexedDB and syncs once after writes recover. Mobile template and
navigation controls exercise touch input. Existing explicitly desktop-only
pointer/keyboard tests remain scoped as such.

On a host where WebKit can launch:

```text
K_COMMS_FORCE_WEBKIT=true npx playwright test e2e/client-recovery.spec.ts e2e/mobile-webkit.spec.ts e2e/whiteboard.spec.ts --project=webkit --project=mobile-webkit
```

Use an isolated server port with `K_COMMS_EXTERNAL_E2E_SERVER=true` and
`K_COMMS_E2E_BASE_URL` when other worktrees are running. Windows Smart App Control
may block Playwright's WebKit DLLs; record a launch failure as unavailable
evidence, not a product failure or a passing browser check. Linux CI or an
isolated Linux development runtime can run the selected engine checks.

Browser tests use synthetic data and mocked API responses. iPhone emulation is
not physical iOS Safari, and it does not qualify live media, audio routing,
permissions, background interruption, or PWA installation on a device. The
physical-device and assistive-technology receipts in
[usability-validation.md](usability-validation.md) remain required.

## Next performance evidence

Retain cold sign-in/inbox/first-whiteboard traces against a production build on
a declared device, CPU/network profile, release revision, and cache state.
Measure transferred resources separately from navigation-to-ready and
interaction latency; repeat enough runs to report median and tail values.
Profile progressively larger scenes within the server's supported scene limits,
including memory and a typical edit/clear operation. Set latency and memory
ceilings from those measurements and the supported device envelope. Passing this
asset gate alone is not a responsiveness or large-scene performance claim.
