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

## Behavior and release

This refinement changes presentation only. Routes, APIs, schemas, dependencies,
identity and consent gates, private-room recovery, media lifecycle, provider
readiness, and destructive-action confirmations retain their existing behavior.
There is no data migration or preference reset.

Delivery follows the [completion standard](../14-operations/development-to-production-completion-standard.md).
Protected checks and merge produce one immutable image; staging qualifies that
digest before an independent production approval. If staging is unavailable,
production remains blocked. Rollback uses the previously approved digest.
