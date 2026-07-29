# Mobile menu and surface controls standard

Status: implemented UI standard  
Applies to: member pages, guest and instant rooms, drawers, dialogs, and active calls

## Decision

K-Comms places the primary hamburger at the logical end of the top bar: the
physical right edge in the current left-to-right interface.

This keeps the physical left edge available for Back, makes the trigger
predictable across every routed member page and room, and groups call-window
controls in one stable top-right area. The hamburger is always the rightmost
control in that cluster.

The supplied native-window reference informs alignment and predictability, not
literal browser chrome. K-Comms does not reproduce operating-system Minimize,
Restore, or Close controls on normal pages.

## Capability-based surface controls

All surface controls use the shared `AppMenuControls` primitives and Lucide
icons.

| Surface | Controls |
| --- | --- |
| Normal routed page | One global rightmost hamburger on mobile; persistent workspace rail on desktop |
| Hamburger drawer | Close |
| Dismissible drawer or dialog | Close |
| Expandable disclosure | Its existing expand/collapse trigger |
| Active call | Minimize or Restore, then the rightmost hamburger |
| Call termination | Explicit red phone-off action; never an ambiguous X |

Unsupported controls are not displayed. In particular, a dialog that cannot
be minimized or expanded shows Close only.

Controls are ordered predictably when present:

1. Minimize
2. Expand or Restore
3. Close

The primary hamburger remains rightmost in active calls because it opens the
call navigation drawer rather than closing the call.

## Menu and drawer behavior

- Member, room, and call hamburger triggers use the same 52 by 52 pixel target,
  25 pixel three-line icon, dialog semantics, focus ring, and right-edge
  placement.
- Every hamburger drawer opens from the right. Phone layouts do not convert it
  into a bottom sheet.
- Drawer headers place the visible title at the start and Close at the end.
- Drawer and dialog close controls are at least 52 by 52 pixels.
- Primary drawer rows are at least 52 pixels high with a familiar icon and a
  visible text label.
- Mixed navigation and action surfaces use dialog, navigation, and button
  semantics rather than ARIA `menu`.
- Focus is trapped while modal, Escape closes the topmost eligible surface, and
  focus returns to the exact opener.
- Safe-area insets and 200 percent text zoom must not cause horizontal
  scrolling.

## Full-bleed active video

On a phone or short viewport, active video occupies the complete viewport.

- The call root, video stage, grid, and outer video tiles have no decorative
  frame, outer padding, gap, or corner radius.
- Video remains behind the top and bottom controls.
- Top controls are solid white familiar icons on 72 percent dark translucent
  circular plates. The glyph itself is not translucent.
- The bottom action area is a gradient overlay, not a separate framed panel.
- Camera video uses `object-fit: cover`; screen sharing uses
  `object-fit: contain`.
- Participant captions show the name and only exceptional media states.
  Normal `Camera on` text is not repeated.
- Bottom-row captions and screen-share picture-in-picture video stay clear of
  the overlaid call controls.
- Calls with five or more participants retain a 140 pixel minimum tile row and
  scroll vertically instead of shrinking people into unusable cells.
- Speaking is shown without a layout-changing border.
- The call drawer overlays video from the right on a readable surface.
- Call drawer headers, navigation, and actions respect notch, status-bar, and
  home-indicator safe areas.
- Leave call is available inside the modal call drawer and remains an explicit
  phone-off action.

## Control labels

Call-control labels are visible by default for elder-friendly operation.

The call drawer contains one preference action:

- `Hide labels` while visual call captions are visible.
- `Show labels` while visual call captions are hidden.

The device-level preference affects only compact call-control captions. It
never hides menu text, navigation, participant names, warnings, connection
state, or confirmations. Complete accessible button names remain available,
and the change is announced through a polite status region.

## Accessibility fallbacks

- Pointer targets are at least 52 by 52 pixels for primary menu and surface
  controls.
- Visible control labels use at least 14 pixel text.
- Overlay controls use a dual light/dark focus treatment over arbitrary video.
- Reduced-transparency mode removes blur and uses opaque plates and panels.
- Forced-colors mode restores explicit control borders and system colors.
- Controls do not automatically disappear during a call.
- Normal pages do not receive misleading window controls that duplicate PWA or
  browser chrome.

## Acceptance criteria

- At 320, 390, 700, and 760 pixel phone/tablet widths and 844 by 390 short
  landscape, every
  hamburger is rightmost and fully contained.
- Member and room drawers align with the viewport right edge.
- All dismissible drawers and dialogs expose the shared Close control and keep
  their prior task-specific Cancel action where applicable.
- Active video touches every viewport edge beneath overlays.
- Show and Hide labels reverse correctly, persist locally, and do not alter
  accessible names.
- Focus trap, Escape, focus restoration, safe areas, 200 percent zoom,
  reduced-transparency, and forced-colors behavior remain usable.

## Rendered verification evidence

- [390 pixel member menu](mockups/mobile-standard-menu-390-2026-07-28.png)
- [390 pixel notification surface](mockups/mobile-standard-notifications-390-2026-07-28.png)
- [390 pixel instant room](mockups/mobile-instant-room-standard-390-2026-07-28.png)
- [390 pixel edge-to-edge active video](mockups/mobile-active-video-standard-390-2026-07-28.png)
- [Live-source standardized invite dialog](mockups/uniform-surface-control-live-review-2026-07-28.png)
