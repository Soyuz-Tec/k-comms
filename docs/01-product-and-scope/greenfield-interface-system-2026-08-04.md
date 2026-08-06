# K-Comms adaptive interface system

Status: implemented design authority
Date: 2026-08-04
Scope: public entry, authenticated workspace, messaging, calls, whiteboard, directory, files, personal settings, administration, and operations

## Outcome

K-Comms uses one adaptive interface system across phone, tablet, and desktop. The system preserves the existing routes, permissions, content boundaries, accessibility requirements, and protected delivery model while making navigation, page hierarchy, and control ownership predictable.

This is an interface decision, not a service-boundary or data-model change. No architecture ADR is required because APIs, authorization, storage, deployment topology, and runtime units remain unchanged.

## Audit findings closed by this work

1. The desktop workspace rail exposed six unlabeled icons with equal visual weight. It required recall and tooltips instead of recognition.
2. Mobile hid every destination behind a large drawer. Moving between messages, calls, people, files, and personal settings required two actions.
3. Whiteboard was presented as a global peer on mobile even though the product model treats it as a collaboration tool rather than a daily communication destination.
4. The mobile top bar combined workspace identity, room creation, notifications, and navigation in a cramped control cluster.
5. Page containers used different widths, offsets, heading scales, and mobile treatments across calls, files, directory, whiteboard, settings, administration, and operations.
6. Heading scale ranged from oversized display type to metadata too small for comfortable scanning.
7. Empty states occupied large desktop canvases without a consistent next action or compositional anchor.
8. Personal settings rendered jump links and privileged tools before the page title, reversing the document hierarchy.
9. Administration used the same oversized marketing-style heading treatment as lightweight member pages despite much denser content.
10. The signed-out instant-room setup panel used small labels and secondary copy beside a visually dominant canvas.
11. Messaging conversation actions became crowded at intermediate widths, while the navigation rail still consumed space without providing labels.
12. Multiple CSS layers independently redefined mobile shell dimensions and navigation height, allowing responsive behavior to drift.
13. Canvas actions were not governed by an explicit ownership rule, making it possible for destructive canvas controls to leak into general room or account menus.
14. Notification, account, install, role, and room-creation actions were duplicated inconsistently between desktop and mobile menus.
15. Active state, target sizing, safe-area spacing, focus treatment, and reduced-motion behavior needed one explicit shell-level contract.

## Information architecture

### Desktop workspace sidebar

At wide desktop widths, the persistent sidebar uses labels and groups:

- Communicate: Inbox, Calls
- Collaborate: Whiteboard, Directory, Files
- Personal: You

The primary workspace action is `New instant room`. Notifications and the signed-in account remain anchored at the bottom. Administration and operations remain role-gated account tools, not general member destinations.

At tablet and compact desktop widths, the same sidebar collapses to an accessible icon rail. Labels remain available to assistive technology and as native titles; no destination changes position or meaning.

### Mobile workspace navigation

The persistent bottom navigation contains exactly five daily destinations:

- Inbox
- Calls
- Directory
- Files
- You

Whiteboard, instant-room creation, installation, privileged tools, and account actions live in the `More` drawer. This follows the mobile product model: daily movement is one tap, while less frequent or contextual actions remain available without crowding the primary bar.

The top bar contains only product/workspace identity, notifications, and `More`.

### Control ownership

Controls live with the object they affect:

- Canvas controls: drawing tools, original K-Comms starter templates, canvas object count, undo/redo, board clear, zoom, export, and canvas collaboration state.
- Conversation controls: conversation workspace navigation, message composition, attachments, reactions, replies, participants, and conversation sharing.
- Call controls: microphone, camera, screen share, participants, device selection, minimize/restore, and leave/end call.
- Room controls: invite link/QR, room membership, room lifecycle, save/leave, and room-level audio/video entry.
- Account controls: profile, password, devices, sessions, notifications, install, and sign out.
- Administration controls: people, safety, governance, integrations, service accounts, and tenant audit.

`Clear canvas` is destructive and must remain inside canvas controls with confirmation. It must not appear in the general room menu. Canvas object count belongs beside canvas composition or canvas controls, not beside room creation or messaging actions.

## Interface rules

1. Use semantic tokens from `theme.css`; component styles do not introduce an independent palette.
2. Wide member pages share a readable content measure, page padding, heading scale, card boundary, and section rhythm.
3. The workspace shell uses one responsive breakpoint contract: labeled sidebar at wide widths, compact rail at intermediate widths, top bar plus bottom navigation on phone or short viewports.
4. Interactive targets are at least 44 CSS pixels; primary mobile navigation targets are 52 pixels or taller.
5. Mobile fixed controls respect safe-area insets. Scrollable content reserves both top-bar and bottom-navigation space.
6. Every icon-only control has an accessible name. Labels are visible whenever space allows.
7. Active navigation uses color, surface, and position; it is never indicated by color alone.
8. Page titles precede local navigation and role-gated shortcuts in DOM and visual order.
9. Empty states identify what is empty, why it may be empty, and the highest-value next action when one exists.
10. Motion is optional decoration and respects `prefers-reduced-motion`.
11. Full-screen or modal call surfaces may cover the workspace navigation but must preserve their own explicit minimize, restore, close, and leave controls.
12. Route, permission, and server-side authorization behavior is not inferred from visual availability.

## Surface acceptance criteria

### Public and sign-in

- Instant-room creation remains canvas-first and works signed out or signed in.
- Authentication opens as a focused gateway over the same local canvas instead
  of replacing it with a separate promotional page. The canvas is visibly
  preserved but inert while credential, invitation, or workspace-setup fields
  are active; no protected workspace data loads before authentication.
- Setup typography is legible at desktop and phone widths.
- Account sign-in is clearly secondary to instant collaboration on the public page.
- Invite and guest-join flows retain their security and identity disclosures.

### Messaging

- Desktop retains the conversation list and message pane without overlapping the workspace sidebar.
- Mobile supports direct movement to all five primary destinations.
- Composer, attachment, participant, call, search, and detail controls remain reachable and named.
- The conversation header separates identity and live status from contextual `Chat`, `Canvas`, `Activity`, and `Details` navigation.
- Compact search, call, and invitation controls retain accessible names and 44-pixel targets.
- The composer identifies its recipient and local draft state, groups the message field with its primary actions, and keeps mentions and keyboard guidance in a supporting toolbar.

### Calls

- Call history and start-call actions follow the common page heading and content measure.
- Active-call overlays reserve or intentionally cover shell controls without leaving ambiguous duplicated actions.

### Whiteboard and canvas

- Whiteboard is grouped under collaboration on desktop and available from `More` on mobile.
- The searchable template gallery presents original K-Comms brainstorm, planning, strategy, and reflection layouts at desktop and phone widths.
- Applying a template adds supported drawing objects beside existing work; it never replaces or clears the current scene.
- Canvas-destructive actions require confirmation and remain in canvas controls.
- Room lifecycle and canvas lifecycle remain distinct.

### Directory and files

- Both use the common content alignment and mobile primary navigation.
- Search, filters, empty states, upload, and primary actions retain accessible names and usable target sizes.

### You, administration, and operations

- `Profile and settings` is the first page heading before jump links or role tools.
- Role tools are permission-gated and visually secondary to personal settings.
- Administration and operations use the common restrained heading hierarchy and content measure.

## Verification contract

The change is complete only after:

1. Focused component tests prove navigation membership, labels, active state, role gating, drawer behavior, and heading order.
2. Web lint, type checking, unit tests, production build, and accessibility checks pass.
3. Desktop and phone renders are inspected for signed-out instant-room, sign-in, Inbox list and conversation, Calls, Whiteboard, Directory, Files, You, and administration.
4. No horizontal overflow, hidden primary action, inaccessible icon control, or shell overlap is present at the verified viewports.
5. The protected release uses the repository completion standard, immutable artifact identity, staging qualification, approval, same-digest production promotion, and public verification.

## Rollback

This work is isolated to interface components, tests, documentation, and CSS. Runtime rollback uses the last known-good immutable image under the standard deployment procedure. Source rollback can revert the interface commit without data migration or API compatibility work.
