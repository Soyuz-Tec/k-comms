# Adaptive navigation dock

## Decision

Desktop K-Comms uses a transparent 48px floating navigation dock with 44px controls. It reserves no workspace column and hides after eight seconds without menu activity. Moving deliberately to the leftmost six pixels and pausing for 250ms reveals it. A small edge mark retains a 44px named button for touch and keyboard access. The 240px labeled surface opens for keyboard navigation or explicit pinning; pointer use keeps the compact dock narrow. Revealing, hiding, and expanding never change the workspace geometry. The existing local pin preference is retained.

## Interaction contract

- Every icon-only destination keeps its accessible name and exposes a native tooltip.
- Keyboard focus expands the dock and prevents idle hiding. `Escape` hides an unpinned dock; its contents become inert and leave the accessibility tree and tab order. The named reveal button remains reachable.
- Only menu activity renews the eight-second timer. Work elsewhere in the application does not keep menus on screen. Clicking the workspace dismisses the unpinned dock immediately.
- Open account and notification menus, keyboard focus, and explicit pinning prevent idle hiding. Drags and brief edge crossings do not reveal the dock.
- The compact dock has no panel fill, border, or shadow. Individual controls have translucent backplates so dark-mode icons remain legible over a white drawing canvas. Expanded labels and account popovers use a readable surface; reduced-transparency and forced-color preferences restore a solid backdrop.
- The activation control exposes `aria-expanded` and `aria-pressed` so temporary expansion and the persisted pin state remain distinguishable.
- Tablet widths use the same overlay dock. Phone navigation remains the existing fixed, touch-sized primary navigation and is still removed during immersive call surfaces.

## Validation

Rendered acceptance covers compact/hidden/expanded geometry, idle hiding during ordinary workspace activity, intentional edge reveal, keyboard recovery, open-menu and pin protection, no workspace reflow, and the phone/tablet/desktop reference UI matrix in both themes.
