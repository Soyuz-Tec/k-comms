# K-Comms desktop UI audit

**Audit date:** 2026-07-26
**Primary target:** React frontend at `https://comms.avayaworks.com/`
**Supporting target:** `C:\Users\vasan\OneDrive\Documents\k-comms`, branch `agent/mvp-staging-completion`
**Reference viewport:** 1280×720 and 1440×900 desktop

## Executive verdict

K-Comms has a credible, distinctive visual foundation: the forest/teal palette is calm, the typography has character, the authenticated areas are structurally accessible, and the core messaging workflow is understandable.

The main desktop weakness is information architecture rather than styling. The signed-in experience behaves like a compact responsive UI spread across a wide screen. Navigation, account, workspace, and primary actions compete in a fragmented top bar; important metadata is too small; onboarding cards displace working content; and Calls, Directory, and Files leave large areas of the desktop canvas unused.

The recommended direction is a compact workspace rail, a denser conversation column, and one flexible conversation canvas. Secondary information should appear only when requested. This preserves the existing product structure and visual identity while improving scan speed and reducing navigation cost.

## Minimalism gap analysis

The first redesign mockup improved hierarchy but still exposed too much at once:

- A wide labeled navigation rail repeated information that icons and tooltips can communicate.
- The permanent context panel made members, files, pins, call state, mute, and settings compete with the conversation.
- Workspace name, user role, account identity, presence, and notification state appeared in multiple places.
- Filter pills, bordered sections, status cards, and secondary actions made every region look equally important.
- Four permanent columns reduced the calm working area and made the interface feel like a control center rather than a communication workspace.

The minimalist revision uses progressive disclosure:

- One 80 px icon rail.
- Workspace identity reduced to a single avatar and short name.
- One conversation list with search and two text filters.
- One conversation canvas.
- Members, files, pins, settings, and other details moved behind one Details action.
- Borders establish structure; cards and shadows are reserved for overlays.

## Evidence reviewed

- Live instant-room and sign-in React routes on `comms.avayaworks.com`.
- Current signed-in messaging, Calls, Directory, and Files states rendered from the repository's existing Playwright fixtures.
- `ProductShell.tsx`, `ChatPage.tsx`, shared styles, page-specific styles, route structure, and accessibility tests.
- Targeted automated WCAG A/AA checks for populated messaging, Calls, Directory, and Files: **4 passed**.

Automated checks are useful evidence, but they are not a substitute for manual keyboard, screen-reader, zoom, and real-data usability testing.

## What is already working

- Clear product personality without copying a generic chat application.
- Consistent forest, mint, cream, and teal palette.
- Strong semantic structure, visible focus treatment, route focus management, and skip-link support.
- Understandable two-pane messaging model.
- Explicit connection, safety, file-scan, and trust states.
- Action targets are generally large enough, especially in forms and newer member surfaces.
- Desktop and mobile share a coherent product model rather than behaving like separate products.

## Prioritized improvements

### P1 — Replace the fragmented top bar with a persistent workspace rail

The current top bar distributes the logo, account, workspace, section links, instant-room action, notifications, and sign-out across two visual rows. At 1280×720 it consumes attention while still making the navigation labels unusually small.

Use a 72–88 px left rail on desktop:

- Brand and minimal workspace switcher at the top.
- Inbox, Calls, Directory, Files, and You as stable icon actions with accessible names and tooltips.
- A compact “New” action for conversations or instant rooms.
- Account avatar at the bottom; identity and sign-out live in its menu.
- Keep the existing mobile bottom navigation below the desktop breakpoint.

This creates a predictable navigation home and removes repeated top-bar parsing on every page.

### P1 — Raise the desktop type floor

Several current styles render metadata between `0.59rem` and `0.73rem`; at normal desktop scale this is approximately 9–12 px. The result is technically visible but tiring to scan.

Recommended floor:

- Primary body and messages: 14–16 px.
- Navigation and controls: 13–14 px.
- Metadata, timestamps, and helper copy: 12–13 px.
- Reserve 11 px only for short uppercase eyebrow labels.

Increase contrast for timestamps, offline state, composer hints, and secondary row copy.

### P1 — Make the inbox a working queue, not an onboarding surface

The “Bring in your teammate” card consumes a large part of the conversation column even when a conversation exists. It competes with the user's actual work.

- Show the full onboarding card only in a truly empty workspace.
- Collapse it to a single dismissible row once any conversation exists.
- Give conversation rows a preview line, sender, timestamp, unread count, and room/direct icon.
- Keep search and filters visible, but combine the three icon-only header buttons into one clear “New” action plus overflow.

### P1 — Put conversation context behind progressive disclosure

The current “Details” button hides useful context behind another step and leaves the conversation canvas visually empty with sparse data.

Keep one Details action in the conversation header. It can open an on-demand drawer for:

- Members and presence.
- Pinned items.
- Shared files.
- Call state and upcoming room action.
- Conversation settings for authorized users.

Do not keep the drawer permanently open by default. Close it when the user changes conversations unless they explicitly pin it.

### P1 — Do not show a false blocking security warning during capability loading

On the live HTTPS sign-in page, the initial render briefly shows “HTTPS is required,” disables every credential field, and then enables the form after the secure-capability request resolves. This severe transient state looks like a deployment failure even when the site is healthy.

- While the transport policy is unresolved, show a neutral inline state such as “Checking secure connection…”.
- Render the warning only after an explicit denial.
- Keep the form geometry stable to avoid visual shift.
- If resolution takes longer than a short threshold, provide “Retry security check” rather than leaving the page apparently broken.

### P2 — Give Calls a desktop-first command hierarchy

The Calls page has two large stacked cards, small row actions, and considerable unused space.

- Use a two-column layout: active/recent sessions on the left, “Start from a conversation” on the right.
- Make “Audio” and “Video” clear primary choices after selecting a conversation.
- Surface active call status and rejoin action above historical data.
- Keep media filters close to the list they affect.

### P2 — Make Directory and Files denser, sortable work surfaces

Both pages are clean, but a single row sits inside a large canvas with no desktop-scale structure.

- Use a compact list/table at desktop widths and preserve card rows on mobile.
- Add visible sort and filter summaries.
- Keep row actions consistently aligned at the right.
- Files should expose source conversation, uploader, size, date, safety state, and download action as stable columns.
- Directory should expose presence, role, and recent interaction without making users open a profile first.

### P2 — Reduce card-on-card styling

The current pages combine a tinted canvas, bordered page cards, bordered inner cards, shadows, rounded controls, and pill segments. The result is polished but visually busy.

- Use one primary surface per area.
- Reserve shadow for overlays, floating calls, and menus.
- Use borders and spacing for ordinary content grouping.
- Keep the serif display face for page and conversation titles; use the sans face for operational labels and dense data.

### P2 — Fit authentication inside common laptop heights

The sign-in story is attractive, but the card can exceed a 768–900 px viewport once the instant-room callout, warning, form, recovery link, and alternate actions are present.

- Cap vertical padding based on viewport height.
- Keep the primary sign-in action visible without scrolling at 1366×768.
- Move infrequent invitation/setup actions into a compact secondary row or progressive disclosure.
- Preserve the current two-column story layout on wide screens.

## Mockup design decisions

The companion mockup applies the recommendations without changing the product's feature model:

- Compact 80 px forest workspace rail with icon navigation.
- Workspace identity shown once, with only an avatar and short name.
- 340 px inbox column with richer conversation previews.
- Flexible conversation area with readable metadata and a stable composer.
- Members, files, pins, and settings behind one Details drawer rather than a permanent panel.
- Flat surfaces, one-pixel dividers, no decorative cards, and no persistent shadows.
- Current K-Comms palette and accessible teal primary actions.
- No new backend concepts or route changes.

## Suggested delivery sequence

1. Fix the transient transport-warning state and raise the type floor.
2. Introduce the compact desktop rail behind the existing mobile breakpoint.
3. Refine inbox density and onboarding behavior.
4. Add an on-demand conversation details drawer.
5. Apply the same rail and density system to Calls, Directory, Files, You, Admin, and Ops.
6. Validate at 1280×720, 1366×768, 1440×900, 200% zoom, forced colors, reduced motion, keyboard-only, and a representative screen reader.
