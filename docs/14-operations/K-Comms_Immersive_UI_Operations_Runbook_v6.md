# K-Comms Immersive UI Operations Runbook v6

**Status:** Companion rollout and rollback runbook  
**Date:** 27 August 2026  
**Authoritative product contract:** [K-Comms Immersive Full-Canvas UI Engineering Prompt v6](../01-product-and-scope/K-Comms_Immersive_Full-Canvas_UI_Engineering_Prompt_v6.md)  
**Implementation companion:** [K-Comms Immersive UI Implementation Reference v6](../12-development-guides/K-Comms_Immersive_UI_Implementation_Reference_v6.md)

This runbook governs staging qualification, progressive delivery, emergency disable, rollback, monitoring, and incident classification for the first Immersive UI increment. It does not authorize a production rollout while required names, thresholds, or evidence remain `TBD`.

---

## 1. Required ownership record

Complete before staging qualification:

| Responsibility | Named owner | Approval/evidence |
| --- | --- | --- |
| Product decision | `TBD` | Contract approved/rejected with date |
| Web implementation | `TBD` | Vitest/Playwright evidence |
| Backend/domain policy | `TBD` | Capability and admission fixtures |
| Media/realtime | `TBD` | One-room continuity and trace evidence |
| Accessibility | `TBD` | axe, forced colors, keyboard, screen-reader review |
| QA | `TBD` | Four-project matrix and exploratory sign-off |
| Release engineering | `TBD` | Staging, cohort rollout, rollback rehearsal |
| Cloudflare/DNS/origin operations | `TBD` | Edge/origin readiness check |
| On-call escalation | `TBD` | Paging route and incident commander |
| Capability removal decision | `TBD` | Target removal date and fallback-retirement decision |

No role may be left as a generic team name at production approval; record one accountable person and one backup where the organization requires it.

## 2. Rollout control design

### 2.1 Existing capability channels

Immersive rollout must use the application’s existing capability responses:

- `/api/v1/status.capabilities.immersive_mode` is the service-level availability and emergency-disable output. It is driven by the `IMMERSIVE_MODE_ENABLED` environment variable and defaults to `false`.
- authenticated tenant/user targeting is returned through the existing `UserCapabilities.allow_immersive_mode` field;
- guest eligibility is returned through the existing `GuestCapabilities` family;
- instant-room eligibility, if independently targeted, is returned through its existing preview/session response.

The client combines these inputs in one pure eligibility selector. There is no new rollout SDK, local-storage authority, parallel endpoint, or second polling provider.

### 2.2 Source of truth

The backend may derive the returned Boolean from configuration or an established server-side feature-control system, but the browser contract stays the same. The emergency action makes the service capability evaluate `false` for new joins.

Required properties:

- server-controlled without a browser redeploy;
- default false when missing or malformed;
- auditable change record with actor, timestamp, prior value, new value, reason, and cohort;
- tenant/user rollout where required without exposing cohort logic to the client;
- cached for no longer than the approved rollback objective;
- no call/message/participant content in targeting or audit telemetry.

### 2.3 Join-time decision

- Capability retrieval begins at prejoin.
- Join waits no more than 300 ms for pending state.
- Unresolved/denied/malformed state at the deadline selects the legacy UI.
- The choice freezes before LiveKit connect begins and remains sticky for that joined call.
- A late positive result applies only to the next call.
- Emergency disable prevents new Immersive entries. It does not reconnect an existing call.

## 3. Fallback and rollback contract

The fallback is the complete current production call presentation: existing `CallPanel`, dock/minimized behavior, persistent panel, route behavior, and the same room/media owner. It is not a partially rendered Immersive stage.

### 3.1 Emergency disable procedure

1. Confirm the symptom is presentation-specific and not a general service, origin, DNS, Phoenix, or LiveKit outage.
2. Record incident timestamp in UTC, affected cohorts, browsers, routes, and current capability value.
3. Set `IMMERSIVE_MODE_ENABLED=false` and apply the configuration, so `/api/v1/status.capabilities.immersive_mode` reports `false` for all new joins. The value is read from application configuration at boot, so applying it restarts the application -- it does **not** require a client or browser release, which is what keeps step 5 a config change rather than a deployment.
4. Wait out the client's status poll rather than purging anything. There is no capability cache to invalidate: the workspace re-fetches `/api/v1/status` every 15 seconds while its tab is visible, and immediately on window focus or a visibility change. A visible tab therefore picks the disable up within ~15 seconds; a backgrounded tab picks it up when the user returns to it, before they can start a new call. Do not purge application or media caches -- they are not part of this path.
5. Start a fresh eligible prejoin and verify the next call uses legacy presentation without a browser redeploy.
6. Verify one existing Immersive call remains connected and does not remount/reconnect because of the change.
7. Verify guest and instant-room behavior separately.
8. Record screenshots, response payload category, call connection count, and the release/config audit event without recording user content.
9. Keep the capability disabled until the incident owner approves a new staged qualification.

If the capability control cannot be changed, returns an ambiguous outcome, or cannot be verified, stop rollout and use the application release rollback procedure. Do not repeatedly toggle an uncertain control.

### 3.2 Same-session downgrade

Same-session visual downgrade is optional and not assumed. If it is later implemented, it may replace only presentation wrappers and overlays while retaining:

- the same `CallSessionProvider`;
- the same `useLiveKitRoom.ts` instance;
- the same attached media elements/tracks;
- current local publication state;
- current screen-share state;
- the single teardown authority.

A downgrade that reconnects media or silently changes microphone/camera/share state is rejected.

## 4. Edge, origin, and application health classification

Do not diagnose every failed UI rollout as a client regression. Establish reachability before interpreting product telemetry.

| Layer | Checks | If failed |
| --- | --- | --- |
| Cloudflare edge/DNS | HTTP status/body, `cf-ray`, `cf-error-type`, `cf-error-origin`, DNS records/CNAME target | Treat as edge/origin-resolution incident; pause UI rollout |
| Application origin | Direct authorized health/readiness path, load balancer/ingress, Phoenix readiness, dependency health | Treat as origin/application availability incident |
| Media origin | LiveKit endpoint/TLS/token issuance/connectivity | Treat as media-plane incident; do not blame overlay state |
| Capability path | `/api/v1/status`, identity/surface capabilities, cache age, join deadline | Treat as rollout-decision incident; fail closed to legacy |
| Presentation client | stage/overlay rendering, one-room invariant, errors/traces | Treat as Immersive UI incident only after earlier layers pass |

Cloudflare documents HTTP `530` as an origin-hostname resolution failure; the response body may contain the more specific 1XXX code. Capture the exact URL, UTC time, headers, body code, and Cloudflare Ray ID. Verify the DNS A/AAAA record or external CNAME target and the load-balancer/origin hostname before changing UI code. See Cloudflare’s official [Error 530](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-5xx-errors/error-530/), [Error 1016](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-1xxx-errors/error-1016/), and [diagnostic header](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-error-headers/) guidance.

An edge/origin outage invalidates UI success-rate comparisons for the affected window. Annotate or exclude the interval; do not trigger product rollback solely from corrupted availability data.

## 5. Pre-production qualification

### 5.1 Static and component gates

- TypeScript/build/lint checks pass.
- The implementation branch’s actual Vitest baseline is recorded; no unexplained test loss is allowed.
- New state, capability deadline, drag, collision, teardown, capacity-copy, and continuity tests pass.
- Backend/domain tests prove effective instant-room boundaries for tenant policies below/equal/above 25.
- No code or test describes 49 as a supported capacity.

### 5.2 Browser matrix

Run:

- `chromium`;
- `chromium-dark`;
- `mobile-chromium`;
- `webkit`.

Required scenarios:

- authenticated join, Workspace navigation, `CallCompanion`, return to Immersive;
- guest join/leave and instant-room join/leave without authenticated shell leakage;
- capability enabled, denied, missing, malformed, 300 ms timeout, late positive, and emergency disabled;
- remote end and terminal disconnect in both presentation modes;
- Phoenix reconnect with media live and media reconnect with Phoenix live;
- standalone whiteboard with active call during pointer, stylus-equivalent, text editing, dialogs, and mobile keyboard;
- in-call whiteboard presentation with captions and Stop Presenting;
- second call decline, accept, pending leave, failed leave, and successful switch;
- reduced motion, forced colors, dark palette, keyboard-only, axe, zoom/reflow;
- 1/4/16/49 tile layout/performance fixtures, with 49 labeled stress-only.

### 5.3 Performance gates

On the recorded reference device and browser build:

- reveal responds within 100 ms;
- stage rectangle remains within 1 CSS px before/after overlay transitions;
- transition-attributable CLS is `0.00`;
- unthrottled drag targets 60 fps;
- 4× CPU-throttled controls respond within 200 ms, drag sustains at least 30 fps, and no interaction task exceeds 100 ms;
- route/mode transitions produce one room connection, no republish, and no media renegotiation;
- pointer frames produce no backend/Channel/analytics event.

Retain trace artifacts with release evidence.

### 5.4 Rollback rehearsal

In staging:

1. qualify an eligible Immersive join;
2. keep that call active;
3. disable the service capability;
4. prove the active call does not reconnect or remount;
5. start a second fresh eligible session and prove it uses the complete legacy UI;
6. repeat for guest and instant-room surfaces;
7. re-enable only for the staging cohort and prove the next fresh call becomes Immersive;
8. record timestamps and cache propagation time.

The measured propagation time becomes the operational rollback objective. If it exceeds the approved objective, rollout is blocked.

## 6. Progressive rollout

Use cohorts that are large enough to observe behavior but small enough to stop safely.

| Stage | Cohort | Required hold/evidence | Exit condition |
| --- | --- | --- | --- |
| 0 | Local/CI | All automated gates | No failures |
| 1 | Staging staff | Full qualification and rollback rehearsal | Owners sign evidence |
| 2 | Internal production users | At least one business cycle or approved call volume | Guardrails healthy; support review complete |
| 3 | Named low-risk tenant/user cohort | Predeclared duration/volume | No material regression by browser/surface |
| 4 | Expanded cohorts | Stepwise expansion | Each step separately approved |
| 5 | General availability | All eligible users | Legacy retirement remains separate decision |

Do not expand two stages in one change. Do not change the client release and cohort rule simultaneously unless incident recovery requires it and the incident commander records the reason.

## 7. Metrics and guardrails

Set numeric thresholds before Stage 2. `TBD` thresholds block rollout.

### 7.1 Reliability guardrails

- join attempt → usable controls success rate;
- time from Join to usable controls;
- initial LiveKit connection failure;
- reconnect frequency and terminal disconnect rate;
- duplicate-room or duplicate-publication invariant violations;
- leave/end/Stop Sharing action failure;
- capability timeout and malformed/missing rate;
- legacy fallback rendering failure;
- client error rate partitioned by route, surface, browser project, and presentation choice.

### 7.2 UX/performance guardrails

- overlay reveal latency p50/p95;
- stage-layout-shift violations;
- drag frame duration/drop rate from sampled diagnostics, never per frame telemetry;
- off-screen placement recovery;
- companion collision fallback frequency;
- accessibility preference use and failure signals;
- accidental leave confirmation cancellation;
- support reports of hidden controls, lost work, navigation confusion, or whiteboard obstruction.

### 7.3 Privacy rules

Do not collect media, captions, whiteboard content, messages, filenames, participant names, or document content. Use coarse surface categories and pseudonymous release/session identifiers subject to existing privacy policy. Never emit telemetry per pointer movement or drag frame.

## 8. Predeclared stop conditions

Insert approved numeric thresholds before rollout. At minimum, stop expansion and evaluate emergency disable when any of the following occurs:

- join-success or usable-controls rate breaches its threshold;
- duplicate room/media publication invariant is observed;
- mute, Leave/End, or Stop Sharing fails or appears falsely successful;
- capability timeout/malformed rate breaches threshold;
- legacy fallback fails to render completely;
- captions or critical whiteboard controls are obscured in a supported viewport;
- a keyboard-only or forced-colors blocker is found;
- stage layout shift or media reconnection occurs from overlay movement;
- support volume indicates users cannot find controls or return to the call;
- edge/origin health makes experiment data unreliable.

Safety/privacy failures trigger immediate disable regardless of aggregate rate.

## 9. Incident response matrix

| Symptom | First classification | Immediate action | Evidence |
| --- | --- | --- | --- |
| Cloudflare 530 | Origin hostname/DNS resolution | Pause rollout; capture 1XXX/body and diagnostic headers; verify DNS/CNAME/origin | URL, UTC time, Ray ID, headers, DNS result |
| Blank/partial Immersive stage, legacy works | Presentation path | Disable Immersive for new joins | Browser, route, capability inputs, console/trace |
| Both Immersive and legacy fail to join | Media/backend/edge | Keep rollout paused; investigate token/origin/LiveKit | readiness, token response category, LiveKit state |
| Controls hidden with critical state missing | Safety UI | Emergency disable | viewport, state, a11y prefs, screenshot without content |
| Second room connects before first leaves | Media invariant | Emergency disable; page Media/Realtime owner | room IDs hashed, lifecycle log, publication count |
| Whiteboard editing obstructed | Collision/accessibility | Stop affected cohort; disable if no safe workaround | viewport, active zones, overlay placement |
| Late capability positive upgrades active call | Stickiness invariant | Emergency disable | monotonic timing, connect dispatch, component mount counts |
| Instant-room rejects below 25 | Expected for lower tenant policy when at effective boundary | Verify server-provided limit; do not label UI failure automatically | tenant policy category, effective limit, boundary response |
| 49-tile fixture degrades | UI stress result | Block expansion until budget met or target explicitly revised | trace and hardware profile; no capacity claim |

## 10. Failure-state requirements

Qualify explicit UI states for:

- camera/microphone permission denied, ignored, policy-blocked, absent, and busy;
- selected device removed during a call;
- screen share canceled/denied and browser-ended sharing;
- LiveKit initial failure, reconnect, partial media failure, and terminal disconnect;
- Phoenix reconnect while media is connected and the reverse;
- overlay placement invalidated by resize, zoom, orientation, safe-area, keyboard, or PWA display mode;
- capability missing, timed out, malformed, denied, and emergency disabled;
- remote call end while the user is on a Workspace route;
- failed/pending leave during a requested call switch;
- high contrast, reduced motion, opaque controls, and screen reader use.

Recovery must preserve truthful state. Do not show fake success to make the interface feel smoother.

## 11. Release evidence package

Attach to the release/PR record:

- named approval table;
- commit SHA and exact capability configuration revision;
- Vitest baseline and result;
- four Playwright project results;
- axe/forced-colors/manual accessibility evidence;
- instant-room effective-boundary domain results;
- 1/4/16/49 rendering traces with 49 labeled stress-only;
- one-room route-continuity evidence;
- capability deadline and late-positive evidence;
- staging rollback rehearsal with measured propagation time;
- edge/origin readiness result;
- cohort, guardrail thresholds, decision timestamp, and removal date.

## 12. Documentation migration and repository hygiene

The canonical documentation set is:

```text
docs/01-product-and-scope/
  K-Comms_Immersive_Full-Canvas_UI_Engineering_Prompt_v6.md
docs/12-development-guides/
  K-Comms_Immersive_UI_Implementation_Reference_v6.md
docs/14-operations/
  K-Comms_Immersive_UI_Operations_Runbook_v6.md
```

Repository maintainer procedure:

1. Place the three byte-verified files at the canonical paths.
2. Add all three to `DOCUMENTATION-MAP.md` in their existing category/style; do not create a second documentation index.
3. Verify links with the repository’s documentation check.
4. Compare SHA-256 and byte length against the reviewed artifacts.
5. List root `Prompt.md`, `Prompt_v3.md`, `Prompt_v4.md`, or equivalent copies with `git status --short` and checksum them.
6. Only after the canonical set is committed and byte-correct, remove the exact stale untracked root copies. Do not use a glob or recursive deletion.
7. Commit through the normal protected PR workflow. Git history carries later revisions; do not create filename-version copies in the root.

This artifact workspace does not substitute for the canonical checkout. Repository cleanup and `DOCUMENTATION-MAP.md` edits are complete only when the actual repository diff proves them.

## 13. Capability retirement

Do not remove the legacy fallback automatically at general availability. Retire it through a separate decision after:

- the agreed observation window completes;
- all browsers/surfaces meet guardrails;
- rollback has not been needed for the agreed period;
- support and accessibility owners approve;
- the emergency-disable strategy after fallback retirement is documented;
- dead capability fields, tests, and client branches have an approved cleanup PR.

Record the retirement decision, date, approver, and replacement rollback path.
