# Adaptive navigation dock

## Decision

Desktop K-Comms uses a compact 72px navigation dock by default. The full 240px navigation surface expands over the workspace on pointer hover, keyboard focus, or explicit activation. Expansion does not change the workspace content geometry. Users can pin the expanded state; the preference is retained locally.

## Interaction contract

- Every icon-only destination keeps its accessible name and exposes a native tooltip.
- Keyboard focus expands the dock and `Escape` returns it to compact mode unless the user has pinned it open.
- The activation control exposes `aria-expanded` and `aria-pressed` so temporary expansion and the persisted pin state remain distinguishable.
- Tablet widths use the same overlay dock. Phone navigation remains the existing fixed, touch-sized primary navigation and is still removed during immersive call surfaces.

## Validation

Rendered acceptance covers compact and expanded desktop geometry, no workspace reflow while the dock is open, persisted pin state, keyboard Escape behavior, short-landscape phone behavior, and the reference UI matrix at 390px, 1024px, and 1440px in light and dark themes.
