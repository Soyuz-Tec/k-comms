# Workspace interface redesign

Status: Implementation and release acceptance contract

Date: 2026-09-07

Scope: Shared identity, navigation, messaging, calls, whiteboard, public/guest
entry, directory, files, settings, administration and service operations.

This refines the [reference-informed interface](reference-interface-design-2026-09-04.md)
and preserves the [adaptive navigation dock](adaptive-navigation-dock-2026-09-05.md).
It supersedes earlier presentation choices only where explicitly described
below. Existing feature, permission and recovery contracts remain authoritative.

## Design decision

Use Slack-inspired organization and message scanning, Zoom-inspired media
hierarchy, and FigJam-inspired canvas-first controls within one K-Comms identity.
These are design influences, not copied screens or a claim of measured superiority.
The earlier reference contract records the reference sources. No competitor
assets, new dependencies or external search service are introduced.

Shared surfaces use neutral charcoal/light gray with violet reserved for
identity, selection and primary actions. Geist is the shared interface face.
Smaller headings, modest corner radii, separators and continuous lists reduce
nested card framing and keep useful content near the top of the workspace.

| Surface | Change | Preserved behavior |
| --- | --- | --- |
| Desktop navigation | Discoverable menu tab and Go to switcher; readable expanded overlay | Narrow transparent 48px dock, intentional edge reveal, eight-second idle hide, pin preference and no workspace reflow |
| Phone navigation | Shared quieter selection treatment | Five direct destinations and distraction-free conversation/call views |
| Inbox and conversation | Heading/tools row above search; filtered result count; sender/time share a reading line | Authorized title-only inbox, filters, resize, message actions, read receipts, editing and threads |
| Calls | Continuous history list, compact launch area, one actual prejoin mode strip, theme-independent dark stage controls | Default-off microphone/camera consent, device choices, call authority, companion mode and safe-area controls |
| Whiteboard | Compact title/status row, short Chat label, neutral canvas-control trigger | Accessible action names, drawing area, native drawing colors, save/recovery, undo/redo, export and collaboration |
| Files and directory | Continuous separated rows and compact search/filter toolbars | Permission boundaries, safety-state download restrictions, applied filter visibility and source links |
| Public and guest entry | Smaller headings, calmer surfaces and shorter setup steps | Local drafts, room scope, media consent, invite/recovery validation and confirmations |
| Settings | Compact section column, flat workspace shortcuts and sign-out boundary | Existing preference storage, vertical-tab keyboard behavior and session controls |
| Administration | Workspace totals expand on demand; phone section grid stays visible | Counts in the summary, role/step-up gates, tables, audit and policy workflows |
| Operations | Compact metrics and separated triage rows | Visible health summaries, automatic warning guidance and runbook links |

## Workspace switcher contract

- The desktop dock exposes a labeled search control. Ctrl/Cmd+K opens the
  switcher outside editable fields and existing modal dialogs, preserving
  editor link shortcuts and consent/confirmation focus.
- Search uses only the current authorized workspace conversation snapshot and
  existing screen destinations. It is not message search or server discovery.
- Archived conversations are excluded. Same-name conversations have identity
  disambiguation; typing can find entries beyond the first twelve results.
- Administration and operations links follow existing roles. Expiring
  operations authority is reevaluated while the dialog is open. Servers still
  authorize every protected request; the switcher is not a security boundary.
- The named modal uses the shared focus trap and restoration hook, a combobox
  and listbox, arrow navigation, Enter selection, Escape dismissal, outside
  pointer dismissal and a no-results status. History navigation closes it.

## Architecture and operational impact

This is a web presentation/navigation change within existing component and
provider boundaries. No API, schema, database migration, session format,
permission, service, integration or deployment topology changes are made.
An architecture ADR is not required. The
[architecture overview](../02-architecture/architecture-overview.md) remains
authoritative. No new telemetry or personal-data collection is introduced.

Risks are CSS cascade differences, low-contrast controls, narrow-screen
overflow and keyboard focus regressions. The acceptance checks below address
those risks. Drawing content must never be recolored by application styling.

## Acceptance and evidence

- `reference-ui.spec.ts`: member, privileged and public/recovery screens at
  390/1440px in light/dark, 320/1024px reflow, automated WCAG A/AA checks with
  contrast enabled, file safety and settings keyboard behavior.
- `workspace-redesign.spec.ts`: hidden-dock discovery, pointer and keyboard
  switching, search/no-results, Escape/focus, history closure, role filtering
  and compact administration at 320/390px with long workspace names.
- `navigation-dock.spec.ts`: idle hiding, intentional reveal, pinning,
  keyboard recovery, popover continuity and dark controls over a light canvas.
- Calls, whiteboard, guest, instant-room, accessibility, mobile and immersive
  suites remain applicable. Media fixture checks prove layout/contrast, not
  actual remote-media quality or supported room capacity.
- Unit tests cover destination authorization, same-name identities, result
  limits, search, selected prejoin mode, compact whiteboard controls and
  administration disclosure. Full lint, type, unit and build checks remain
  required along with backend, contract and documentation checks.
- Capture and visually review representative screenshots in both themes;
  synthetic fixtures and automated checks do not replace real-user usability
  studies or a real-device media qualification.

## Release and rollback

Follow the [completion standard](../14-operations/development-to-production-completion-standard.md):
protected PR and required checks, protected merge, one attested immutable
artifact, synthetic staging qualification, independent production approval,
backup and same-digest deployment. Record results in the PR and release
workflow rather than treating this acceptance contract as deployment evidence.
Rollback uses the previous approved image; no data migration or preference
reset is necessary.
