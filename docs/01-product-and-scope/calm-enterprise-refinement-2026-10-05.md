# Calm enterprise interface refinement

Status: Presentation acceptance contract

Scope: The five public/authentication, twelve member workspace, and nine
administration desktop destinations, with their responsive layouts.

Authority: [Reference interface](reference-interface-design-2026-09-04.md) and
[adaptive interface system](greenfield-interface-system-2026-08-04.md).

## Visual direction

Use a neutral navigation rail and main surfaces, with restrained purple for
primary actions and selected destinations. Navigation selection uses a quiet
surface rather than a bordered purple block. Secondary actions, scope filters,
setup steps, and profile avatars remain visually subordinate to the task.

Use the existing self-hosted Geist type scale: 24px desktop page titles, 16px
section titles, 14px form and supporting text, and a 12px metadata floor.
Shared panel radii are 8–10px. Remove repeated nested card frames in policy
forms, meeting agendas, artifacts, saved messages, and document lists. Keep
separators, meaningful status colors, and clear keyboard focus.

CSS ownership stays in the existing theme, shared shell, and feature files.
Do not add a global override layer or recolor authored canvas content or media.

The desktop workspace uses a 52px activity rail, a quiet 240px pinned sidebar,
and a 44px menu/header strip. Primary areas appear in the activity rail; related
workspace tools and role-filtered administration sections use the contextual
sidebar. The account menu has one entry in the rail. Keep one workspace identity
visible and one global navigation toggle. The existing compact dock remains available when
the sidebar is unpinned; its reveal never shifts the workspace. History controls
use only known application history. Browser File/View/Help actions open actual
workspace workflows. The constrained Electron client adds genuine OS Edit menus
and window controls, including on public/authentication screens, through the
finite shell boundary in [ADR-0105](../02-architecture/adr/0105-packaged-electron-uc-client.md).
Installed PWAs retain titlebar exclusion in narrow and short windows. Display
mode changes preserve the mounted public workspace and its drafts. Native menus
remain available during immersive calls; only floating call chrome moves below
the OS controls, while the media stage and provider instances retain their size
and lifecycle.

## Acceptance criteria

- Review all 26 desktop destinations using read-only synthetic fixtures.
- Verify representative 320px and 390px layouts, desktop containment, and both
  light and dark themes. Authentication actions remain in the first narrow
  viewport; admin navigation does not displace the first task excessively.
- Preserve 44px touch targets, visible labels, focused controls, reduced motion,
  forced colors, and current theme/sidebar preferences.
- Check WCAG A/AA rules without suppressing contrast or layout failures.
- Keep the existing file action tracks and responsive table geometry. Profile
  fields align without stretching input heights; mobile forms remain stacked.
- Pass existing lint, type, unit, responsive/reference/accessibility browser,
  production build, PWA, asset-budget, contract, and documentation checks.
- Avoid repeating primary destinations in the sidebar and page tabs. Keep in-page
  shortcuts when navigation is compact or unavailable, including every mobile
  destination outside the five primary tabs. Moving navigation between the sidebar
  and page must preserve mounted content, drafts and media providers.
- Condense default status labels and repeated introductions; preserve field labels,
  target-specific confirmations, role restrictions, privacy scope and recovery help.
  Empty inventory filters remain available when an active filter causes no results.
- Verify keyboard menus, history, role-gated activity shortcuts, dock recovery,
  native command validation, and modal/editor guards. Native packaging remains
  unsigned evaluation; OS signing, storage and media qualification need their
  separate platform receipts.

## Behavior and release

This refinement changes presentation and desktop navigation. Routes, APIs, schemas, dependencies,
identity and consent gates, private-room recovery, media lifecycle, provider
readiness, and destructive-action confirmations retain their existing behavior.
There is no data migration or preference reset.

Delivery follows the [completion standard](../14-operations/development-to-production-completion-standard.md).
Protected checks and merge produce one immutable image; staging qualifies that
digest before an independent production approval. If staging is unavailable,
production remains blocked. Rollback uses the previously approved digest.
