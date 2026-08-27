# K-Comms Adaptive Workspace and Immersive Full-Canvas UI

## Engineering prompt and product contract

**Document status:** Draft implementation contract — approval is blocked until the accountable owner, required reviewers, and decision date are named  
**Revision:** v6 — canonical three-document edition  
**Research and repository verification:** 27 August 2026 against `Soyuz-Tec/k-comms` `main`  
**Product:** K-Comms browser application  
**Target stack:** React, React Router, Vite, TypeScript, Phoenix APIs/Channels/Presence, PostgreSQL, self-hosted LiveKit, `livekit-client`  
**Canonical path:** `docs/01-product-and-scope/K-Comms_Immersive_Full-Canvas_UI_Engineering_Prompt_v6.md`  
**Accountable owner:** `TBD — name one product/engineering owner`  
**Required reviewers:** `TBD — name one reviewer each from Product, Web, Media/Realtime, Accessibility, Backend/Domain, QA, and Release Engineering`  
**Decision date:** `TBD — record approval or rejection before production rollout`

This document is the authoritative product and acceptance contract. Technical detail belongs in the linked [Implementation Reference](../12-development-guides/K-Comms_Immersive_UI_Implementation_Reference_v6.md); release, rollback, telemetry, and incident procedure belong in the linked [Operations Runbook](../14-operations/K-Comms_Immersive_UI_Operations_Runbook_v6.md).

### Revision history

| Revision | Date | Material decision/change |
| --- | --- | --- |
| v1 | 26 August 2026 | Initial full-canvas concept; assumed a Phoenix LiveView browser shell |
| v2 | 26 August 2026 | Retargeted to the shipped React/Vite client; preserved Workspace Mode for non-call work |
| v3 | 26 August 2026 | Bounded the first increment, gated Focus Mode as a hypothesis, and specified call continuity |
| v4 | 26 August 2026 | Recorded the verified call-owner topology and deterministic mobile composition |
| v5 | 27 August 2026 | Added public-call and whiteboard contracts, corrected participant-limit semantics, reused existing capability channels, defined the capability deadline, scoped required fixtures, and split the handoff into contract, implementation, and operations documents |
| v6 | 27 August 2026 | Promoted the corrected three-document set to the canonical v6 filenames and synchronized revision metadata, paths, and cross-document links |

Edit this canonical file in place and use Git history for later revisions. Do not create `Prompt.md` or `Prompt_vN.md` copies in the repository root.

---

## 1. Product decision

K-Comms uses two committed presentation modes and one gated hypothesis:

1. **Workspace Mode** is the default for chat, files, directory, calendar, tasks, activity, conversation triage, and standalone whiteboards. Preserve the production navigation shell and multi-pane information density.
2. **Immersive Mode** is the default after a user joins a call or presentation. Active content fills the application viewport; controls and function menus become accessible, minimizable overlays that reveal on meaningful pointer movement, tap, focus, or shortcut.
3. **Focus Mode** for non-call routes is an experiment only. It must not become reachable in production without a separately approved route/user flag and evidence gate.

The governing rule is:

> Preserve information density while people navigate and triage work. Give joined calls and presentations the full application viewport without permanent navigation chrome.

This is an adaptive workspace, not a universal “hide all navigation” redesign. Calls genuinely benefit from the whole viewport; conversation triage genuinely benefits from persistent structure.

## 2. Architecture and repository facts that must be preserved

Do not redesign the product architecture as part of this UI task.

- The production browser UI is `clients/web`: React, React Router, Vite, TypeScript, and `livekit-client`. Do not introduce Phoenix LiveView, `.heex` templates, a second SPA, or a parallel browser shell.
- Phoenix owns authentication, tenant isolation, authorization, call admission, short-lived scoped LiveKit tokens, product state, durable messaging, and audited operations.
- PostgreSQL remains the durable source of truth. Phoenix Channels and Presence carry authorized product state. LiveKit owns WebRTC media transport; browsers connect directly to LiveKit. Phoenix must never proxy audio or video.
- High-frequency pointer, drag, animation, and layout work stays browser-local. Never send `pointermove`, drag-frame, opacity-animation, or video-layout-frame events to an API, Channel, WebSocket, or analytics transport.
- `CallSessionProvider` already wraps `ProductShellContent`; the React Router `<Outlet />` renders inside it. Its lazy `PersistentCallPanel` already survives authenticated route changes. Preserve this topology. The first increment audits and extends that panel into `CallCompanion`; it does not hoist or duplicate the room owner.
- `DraggableSurface.tsx` already uses pointer capture and has tests. The call dock already has `minimized` state. `useLiveKitRoom.ts` already uses LiveKit adaptive stream and `Track.attach()`. Reuse them.
- `/join` uses `GuestAccessPage`/`GuestShell` outside the authenticated shell. `/` uses `InstantRoomPage` outside the authenticated shell. `/app/whiteboard` uses the existing Excalidraw-based collaborative canvas inside `ProductShell`.
- The application already exposes service capabilities through `/api/v1/status.capabilities`, and authenticated identity capabilities through `UserCapabilities`. Extend those existing channels; do not create a parallel rollout store, endpoint, or client capability abstraction.
- The checked-in global instant-room setting is `INSTANT_ROOM_MAX_PARTICIPANTS=25`, but the admitted limit is:

  ```text
  effectiveInstantRoomLimit = min(
    Authority.instant_room_max_participants(),
    policy.max_conversation_members
  )
  ```

  Therefore, `25` is a global ceiling, not a universal tenant limit.
- No verified repository setting establishes `49` as an authenticated-room participant maximum. `49` is a UI stress target only.
- Vitest/jsdom and Playwright projects `chromium`, `chromium-dark`, `mobile-chromium`, and `webkit` are the existing web test stack. Extend it rather than describing a hypothetical test system.
- Fullscreen, Picture-in-Picture, Document Picture-in-Picture, and Screen Wake Lock are not implemented in the current client and are separately scoped future work.

If a named file has moved in the checked-out branch, find its current equivalent; do not silently create a duplicate abstraction.

## 3. First production increment

### 3.1 In scope

- Preserve Workspace Mode and the shipped inbox/shell composition without regression.
- Enter in-tab Immersive Mode after a user joins an authenticated, guest, or instant-room call.
- Fill the application visual viewport with the active call or presentation stage without depending on browser Fullscreen.
- Convert the existing call UI into a transparent or opaque-on-preference, minimizable, movable overlay system while keeping critical state perceivable.
- Preserve the one existing call/media owner across authenticated route changes.
- Extend the existing persistent call panel into a `CallCompanion` for Workspace routes during an active call.
- Define explicit whiteboard, concurrent-call, mobile keyboard, guest, and instant-room behavior.
- Gate new Immersive entry through the existing capability channels and provide a remote kill switch with the legacy call UI as fallback.
- Build every fixture required by the first-increment acceptance gates.

### 3.2 Out of scope

- Production Focus Mode outside an approved experiment.
- Native browser Fullscreen.
- Standard or Document Picture-in-Picture.
- Screen Wake Lock.
- Platform-wide conversion of non-call navigation into overlays.
- Replacement of the workspace shell, draggable primitive, call dock, call-session provider, persistent call panel, or LiveKit room hook.
- Multiple simultaneous locally joined LiveKit rooms, automatic hold, dual audio, or dual camera publication.

None of the deferred browser APIs blocks in-tab Immersive Mode.

## 4. Experience-mode contract

Define one explicit type:

```ts
type ExperienceMode = "workspace" | "focus" | "immersive";
```

The type is three-valued so a later experiment does not create an incompatible state model, but `ENTER_FOCUS` must return the current state unless the approved Focus experiment flag authorizes the current route and user. First-increment production behavior exposes only `workspace | immersive`.

### 4.1 Mode rules

- **Workspace:** retain the 240 px desktop sidebar, established route headers, 60 px mobile bottom navigation, and route-specific multi-pane layouts.
- **Immersive:** the `ActiveContentStage` fills `100dvw × 100dvh` with tested fallbacks. No permanent top bar, side rail, bottom navigation, or control row consumes stage layout space.
- **Focus:** design-only or flag-gated. Entry and exit must preserve route, selection, scroll, draft, filters, and loaded work state.
- Overlay reveal, hide, expand, collapse, or drag must not change stage dimensions.
- Browser fullscreen is an optional future user action, never the definition of Immersive Mode.
- Interactive overlays respect CSS safe-area insets and the visual viewport, including mobile keyboard changes.

### 4.2 Surface contract

| Surface or event | Default result | Required continuity |
| --- | --- | --- |
| Joined one-to-one/group/audio call | Immersive | Keep one authorized media owner and truthful media state |
| Screen presentation | Immersive | Use `contain`; never crop slides, text, spreadsheets, or application UI |
| Chat, files, directory, calendar, tasks, activity | Workspace | Preserve existing navigation and route composition |
| Standalone whiteboard | Workspace | Preserve shell, board picker, collaboration state, canvas state, and Excalidraw controls |
| Whiteboard presented in a joined call | Immersive | Treat the canvas as active content; do not create a fourth mode or second collaboration session |
| Authenticated user navigates away from the call route | Workspace + `CallCompanion` | Preserve the same call; do not republish tracks or instantiate another room hook |
| Admitted guest joins | Immersive without authenticated chrome | Preserve guest session/capabilities; leave returns only to an authorized guest/conversion/terminal state |
| Instant-room participant joins at `/` | Immersive within the public route | Preserve `InstantRoomPage`/session continuity; never mount authenticated shell or companion |
| Second call arrives while one is joined | Keep current mode and call | Show a truthful notification; do not connect or replace the foreground call |
| User accepts the second call | Explicit switch flow | Complete and reconcile the current leave before joining the next call; never claim success while leave is pending or failed |

## 5. Focus Mode validation gate

Focus Mode is not committed first-increment functionality. Its hypothesis is that some spatially constrained non-call tasks may gain usable area and reduce distraction without losing work context. A wider browser window may already solve the problem.

Before implementing a pilot:

1. Select one route from observed workflows, viewport evidence, and user research. File/document preview is only a prior to test, not the recommended answer.
2. Record the constrained task, target users, baseline behavior, expected measurable benefit, evidence threshold, review date, and expand/hold/remove decision.
3. Prototype discovery, entry, exit, and state restoration before generalizing the state machine across routes.
4. Measure eligible sessions, voluntary entry, repeat use, task completion, zoom/scroll burden, exit reasons, state-restoration failures, and support/confusion signals without collecting document or message content.
5. Remove the experiment if repeat use or task benefit is weak.

## 6. Non-negotiable interaction and safety rules

### 6.1 Active content and overlays

- Camera video may use `cover`; screen shares and detailed collaborative content use `contain` by default.
- Controls reveal within 100 ms after intentional pointer movement, tap, focus, or shortcut.
- Routine controls may collapse after three seconds of true inactivity only when no keep-visible condition applies.
- Focus within an overlay, hover, open menus/dialogs, dragging, pending actions, pinned state, a blocking alert, or an accessibility “Always show controls” preference cancels auto-hide.
- Ignore pointer jitter; do not reset the timer for every pixel of movement.
- Critical microphone, camera, screen-sharing, recording/consent, and connection state remains perceivable in compact form.
- Minimize to a small status capsule or edge tab; do not make the only restore target invisible.
- The overlay may be moved by handle, keyboard, and preset-position controls. Dragging is an enhancement, not the only placement mechanism.
- Use pointer capture and compositor transforms. Clamp to safe bounds and persist normalized placement, not raw pixels.

### 6.2 Immediate actions and motion

Never delay the functional availability of mute, leave, stop sharing, or a permission response until an animation completes.

Use opacity/transform animations of approximately 120–180 ms. Respect `prefers-reduced-motion`; reduced-motion mode removes positional movement. A failed functional action remains visibly failed even if an animation completes.

### 6.3 Captions and whiteboard collision priority

8. Captions must not be covered by the dock, participant filmstrip, or notifications. Give caption position first priority in collision avoidance.

For a standalone whiteboard with an active background call, the drawable Excalidraw plane and its native toolbars, menus, zoom controls, dialogs, collaborator/status controls, and text editor are protected collision zones. `CallCompanion` must first use existing non-canvas page chrome; if that space is insufficient, it collapses to the critical-status capsule in the top safe area. It must not float over the drawable plane while pen/stylus input or an Excalidraw text editor is active. On an in-call whiteboard, use the Immersive overlay system; do not render a second Workspace companion.

Collision priority is: blocking permission/consent state, captions, whiteboard editing/native controls, safety-critical call controls, then routine overlays and notifications.

## 7. Call continuity and capability decision

### 7.1 One call authority

- Preserve the existing `CallSessionProvider` above the authenticated route outlet.
- Extend its lazy `PersistentCallPanel` into the only `CallCompanion`.
- Define one teardown authority for explicit leave, remote end, logout, terminal media failure, and route/surface unmount.
- Workspace navigation must not implicitly mute, stop camera, stop sharing, disconnect, or republish.
- Returning to the call route must reuse the same room hook, attached tracks, publication state, and call identity.

### 7.2 Existing capability channels, not a parallel flag system

Add the Immersive service switch to the existing `/api/v1/status.capabilities` response and corresponding `ServiceStatus` type. When rollout is scoped by tenant/user, add the matching entitlement to the existing server-produced `UserCapabilities`; guest and instant-room eligibility must travel in their existing server-issued surface/session capability response.

Create one client selector, `selectImmersiveEligibility`, that combines the applicable existing capability inputs. Do not create a second capability endpoint, local-storage authority, polling loop, context tree, or rollout SDK solely for this UI.

### 7.3 Evaluation deadline and stickiness

- Begin capability retrieval when the prejoin/guest/instant-room surface loads.
- When the user activates Join, wait at most **300 ms** for a still-pending capability decision before beginning media connection.
- A positive decision received before the media-connect action is dispatched may select Immersive Mode.
- Missing, denied, malformed, or unresolved state at the 300 ms join deadline selects the legacy UI.
- Once media connection begins, the presentation decision is sticky for that joined call. A late positive result applies only to the next call and must not upgrade, remount, reconnect, or churn the active media tree.
- A server emergency disable prevents new Immersive entries. Existing calls retain their selected presentation unless a separately tested same-session visual downgrade exists.

The fallback is the current production call presentation—not a blank or partial stage.

## 8. Capacity and performance contract

### 8.1 Participant boundaries

- Domain/admission tests must calculate the instant-room boundary from `min(global ceiling, tenant policy)` and test the effective boundary plus one rejected participant.
- The required fixture set includes tenant policies below, equal to, and above the global `25` ceiling. A lower-policy tenant must not be treated as a failure of the UI test.
- Browser/UI fixtures consume the server-provided `participant_limit`/effective limit. They must not recalculate tenant policy in React.
- Authenticated-room capacity must come from the authoritative server admission policy. Do not claim that `49` is the supported room maximum.
- Render exactly 1, 4, 16, and 49 synthetic participant tiles as UI layout/performance fixtures. Label `49` as a stress target, independent of admission semantics.

### 8.2 Measurable budgets

- Control response: at most 100 ms normally; at most 200 ms under Chrome DevTools 4× CPU throttling.
- Overlay reveal/hide: stage bounding box changes by no more than 1 CSS px of rounding variance and produces `0.00` transition-attributable layout shift.
- Drag: target 60 fps on the recorded reference device; under 4× CPU throttling sustain at least 30 fps with no interaction task over 100 ms.
- No forced synchronous layout loop, React commit, API/Channel message, or analytics event per pointer frame.
- Overlay changes cause no LiveKit room reconnect, track republish, track restart, or renegotiation.
- Visibility- and size-aware subscriptions remain enabled; hidden/thumbnails must not request inappropriate high-resolution layers.
- Record device, OS, browser build, viewport, throttle setting, trace, median/p95 frame duration, and dropped-frame rate.

## 9. Accessibility, privacy, and truthful state

- All actions are keyboard-operable. Implement WAI-ARIA toolbar behavior, accessible dialogs, deterministic focus return, and visible focus indicators.
- Primary touch targets are at least 48 × 48 CSS px. Test reduced motion, zoom/reflow, forced colors, dark palette, screen reader naming, and keyboard-only use.
- Screen-reader names describe the available action and current state; do not announce visual placement as the only meaning.
- Do not auto-hide while keyboard focus is inside the control system.
- Provide `Always show controls` and opaque/high-contrast control preferences.
- Never suggest that K-Comms can prevent screenshots, OS recording, or another camera from capturing the screen.
- Keep authentication, tenant, authorization, short-lived media-token, recording/consent, retention, and audit decisions on the server. Client visibility is not authorization.
- Recovery must preserve truthful state. Do not show fake success to make the interface feel smoother.

## 10. Required first-increment fixtures and owners

Every acceptance criterion below is gated by a fixture that is part of the first increment. “Fixture unavailable” is a failed gate, not a reason to waive the criterion.

| Fixture/evidence | Accountable role | First increment | Minimum evidence |
| --- | --- | --- | --- |
| Experience reducer and overlay component fixtures | Web UI owner | Required | Vitest state/interaction tests |
| Existing provider/panel continuity fixture | Web + Media/Realtime owners | Required | Route transition proves one room/hook and no republish |
| Guest and instant-room joined-call fixtures | Web + Backend/Domain owners | Required | Authorized entry/leave and shell isolation |
| Instant-room effective-limit fixtures | Backend/Domain owner | Required | Policy below/equal/above 25; boundary accepted; boundary+1 rejected |
| 1/4/16/49 synthetic tile fixtures | Web + Media/Realtime owners | Required | Layout and performance traces; 49 labeled stress-only |
| Whiteboard + active-call collision fixture | Web + Accessibility owners | Required | Desktop, stylus/text edit, mobile, keyboard, native controls protected |
| Concurrent-call fixture | Web + Media/Realtime owners | Required | One local room; explicit switch; failed leave remains truthful |
| Capability deadline/fail-closed fixtures | Web + Backend/Domain owners | Required | positive before connect, timeout at 300 ms, late positive, kill switch |
| Four-project browser matrix and axe/forced-color checks | QA + Accessibility owners | Required | `chromium`, `chromium-dark`, `mobile-chromium`, `webkit` |
| Rollback rehearsal | Release Engineering owner | Required | next eligible call uses legacy UI without redeploy |

Named people must replace role-only ownership in the approval record before implementation begins.

## 11. Acceptance criteria

The first increment is complete only when all applicable criteria pass.

### 11.1 Workspace and mode behavior

- Non-call work preserves the existing shell and route composition by default.
- One three-valued `ExperienceMode` exists; `ENTER_FOCUS` is unreachable without the approved route/user experiment flag.
- Joined calls use a visual-viewport Immersive stage without browser Fullscreen or permanent layout chrome.
- Overlay visibility and movement do not resize the stage.
- A separate `CallCompanion` is absent from the Immersive route.

### 11.2 Continuity and surface coverage

- Authenticated navigation preserves the same call, one provider, one room hook, attached tracks, publication state, and teardown authority.
- Guest and instant-room flows enter Immersive without authenticated chrome and leave only to an authorized surface.
- A standalone whiteboard remains Workspace. An in-call whiteboard becomes Immersive active content without a second collaboration session.
- On a standalone whiteboard with an active call, the companion respects every protected collision zone and yields during stylus/text editing.
- A second active/incoming call never replaces or connects over the foreground call. Switching requires explicit confirmation and a completed current leave.

### 11.3 Visibility, dragging, and mobile composition

- Pointer, tap, focus, and shortcut reveal controls within budget; critical status remains visible while routine controls collapse.
- Every draggable placement is also achievable with keyboard and single-pointer preset controls.
- Overlay position survives reload, clamps after viewport/safe-area change, and never restores off-screen.
- At 390 × 844 CSS px, a joined call hides the 60 px bottom navigation; a Workspace route restores it and shows exactly one constrained companion.
- With the virtual keyboard open, the companion relocates or collapses without covering the composer, keyboard, route-critical action, native whiteboard control, or bottom navigation.

### 11.4 Capability and rollback

- Eligibility uses the existing status/identity/surface capability responses and one client selector; no parallel capability mechanism exists.
- Capability resolution starts at prejoin. Join waits no more than 300 ms; unresolved state selects legacy; a late positive result cannot upgrade an active call.
- Emergency disable blocks the next Immersive entry without a redeploy. The fallback is complete and usable.
- Enabled, disabled, deadline-timeout, late-positive, and emergency-disabled paths are qualified in staging without duplicate media connections.

### 11.5 Capacity, test, and performance gates

- Instant-room admission tests use the effective `min(global, tenant policy)` boundary and boundary+1 across lower/equal/higher policy fixtures.
- Authenticated call fixtures do not claim an unverified numeric capacity. The 49-tile case is recorded as a UI stress target.
- Vitest and all four configured Playwright projects pass; existing axe checks and explicit forced-colors coverage pass.
- The reviewed Vitest baseline has no unexplained reduction; update the recorded baseline to the implementation branch’s actual count before approval.
- Every budget in §8.2 is supported by reproducible test output or a saved trace.

### 11.6 Governance

- Owner, reviewers, decision date, flag owner, operational approver, on-call escalation, guardrail thresholds, and removal date are named.
- This contract and both companion documents are linked from `DOCUMENTATION-MAP.md` and committed through normal Git/PR history.
- After checksum verification of the canonical documents, untracked root `Prompt.md`/`Prompt_vN.md` copies are removed; Git history carries future revisions.

## 12. Reject the implementation if it

- removes the production workspace shell by default for chat, files, directory, calendar, tasks, activity, or standalone whiteboards;
- introduces LiveView, a parallel SPA, a duplicate call owner, a duplicate draggable primitive, or a duplicate capability system;
- treats `25` as every tenant’s effective instant-room limit;
- describes `49` as a supported room maximum without authoritative server provenance;
- lets a late capability result remount or upgrade an active media tree;
- mounts authenticated navigation in guest or instant-room flows;
- covers captions, whiteboard editing controls, or the active Excalidraw text/stylus plane with movable call UI;
- allows two simultaneous local LiveKit room connections in the first increment;
- sends pointer-frame work to the server or analytics;
- makes hover the only way to recover controls;
- hides critical state, delays mute/leave/Stop Sharing for animation, claims fake success, or implies screenshot prevention;
- ships acceptance requirements whose fixtures are not implemented and owned;
- requires Fullscreen, PiP, or Wake Lock for basic Immersive operation.

## 13. Required handoff

The engineering team must deliver:

1. approved contract and named decision record;
2. component/state architecture conforming to the [Implementation Reference](../12-development-guides/K-Comms_Immersive_UI_Implementation_Reference_v6.md);
3. design states for Workspace, Immersive, minimized, expanded, permission failure, reconnecting, guest, instant room, whiteboard, concurrent-call switch, mobile keyboard, reduced motion, forced colors, and legacy fallback;
4. test fixtures and trace evidence listed in §10;
5. staged rollout and rollback evidence conforming to the [Operations Runbook](../14-operations/K-Comms_Immersive_UI_Operations_Runbook_v6.md);
6. updated `DOCUMENTATION-MAP.md`, removal of verified stale root copies, and a reviewable Git diff.

The implementation goal is a workspace-dense communications product that becomes calm and full-canvas when a call or presentation becomes the user’s primary task—without sacrificing truthful state, accessibility, tenant policy, existing React architecture, or operational reversibility.
