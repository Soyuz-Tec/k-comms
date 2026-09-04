# Reference-informed K-Comms interface

Status: Implementation and release acceptance contract

Scope: Public, member, guest, tenant administration, and platform operations

Architecture: [Architecture overview](../02-architecture/architecture-overview.md)

Interface authority: [Adaptive interface system](greenfield-interface-system-2026-08-04.md)

## Decision

Use one K-Comms visual language rather than separate imitations of other
products. Cool neutral surfaces, violet identity, restrained elevation, clear
labels, and consistent selected states connect every screen. Desktop keeps
its persistent, resizable workspace; phones retain the existing five-tab
navigation and distraction-free conversation leaf views.

The references are product-pattern inspiration and design judgment, not a
claim of comparative usability testing or a reproduction of proprietary
screens. No competitor assets, branding, new SDKs, or dependencies are added.

## Screen-by-screen selection

| K-Comms surface | Reference influence | Applied or deliberately retained pattern |
| --- | --- | --- |
| Public canvas and room setup | Zoom collaboration, WhatsApp entry simplicity | Canvas-first entry retained; quiet setup surfaces, a short step indicator, one create-room action, local draft continuity. |
| Sign-in, invitation, recovery, workspace setup | Teams account clarity | One form task, shared surfaces and primary action hierarchy; existing recovery and authorization boundaries retained. |
| Desktop workspace and Inbox | Slack | Persistent labeled navigation, compact rail option, selected-location indicator, resizable conversation list, restrained filters. |
| Phone Inbox and navigation | WhatsApp | Five direct destinations; active icon has a quiet capsule; search/new conversation stay close to the list, no extra global top bar. |
| Conversation and composer | Slack desktop, WhatsApp phone | Flat chronological desktop reading; quiet own-message bubbles on phones; familiar composer and contextual actions. Inbox summaries remain content-free. |
| Search, threads, notifications, action dialogs | Slack, Teams | Shared neutral tokens and selection language; existing focus management, scrollable panels, thread boundaries and action confirmations retained. |
| Calls launch and history | Zoom, Teams | Full conversation identity above labeled Message/Audio/Video actions, calm empty state, independent active/recent filters. |
| Prejoin, active call, participants and device settings | Zoom | Existing media-first stage, explicit default-off consent, persistent call authority and dark media controls retained; surrounding forms use the shared palette. |
| Directory people and rooms | Teams | Search and quick actions remain direct; role-gated invitation shortcut; no additional personal fields or discovery permission. |
| Shared files | Teams, Slack | Desktop columns and phone cards retained; hidden filters expose their applied state and a clear action; unavailable downloads remain disabled. |
| Whiteboard and canvas controls | Zoom collaboration | Canvas gets the working area; direct return to its conversation, phone controls moved off the toolbar, theme-aware control surfaces. |
| Guest invitation and guest room | WhatsApp, Zoom | One-name join, explicit single-room scope, same surfaces and controls, no workspace navigation or directory access. |
| You and settings | WhatsApp simplicity, Teams account organization | Profile identity, icon-labeled sections, readable workspace shortcuts, keyboard navigation for vertical tabs. |
| Administration: workspace, people, safety, governance, integrations, audit | Teams, Mattermost | Dedicated desktop section navigation, fully visible phone section grid, quiet selection, keyboard-scrollable data tables. Existing role and step-up checks unchanged. |
| Service operations | Mattermost private operations | Triage/queue/provider anchors, healthy response guidance collapsed, problems expanded automatically, condition/owner/stop/escalation evidence retained. |

## Implementation ownership

- `clients/web/src/theme.css`: shared semantic palette in light and dark.
- `clients/web/src/interface-system.css`: shell, shared page composition,
  settings and workspace shortcuts; no additional global override layer.
- Existing feature CSS and components own conversation, calls, files, directory,
  guest, whiteboard, administration, and operations internals.
- The drawing surface and video stage keep their independent visual roles.
  Drawing content is never recolored by an application theme change.

## Safety and behavior invariants

- No API, route, schema, provider, permission, session, or deployment-topology
  changes. An architecture ADR is not required for this presentation change.
- No content previews added to inbox summaries; files retain server-authorized
  indexing, scan-state gates, source-message links, and approved download URLs.
- Camera and microphone remain off until explicit consent. No new recording,
  telephony, transcription, or encryption claims are introduced.
- Healthy operations evidence is still visible in each summary. Only response
  detail collapses; warnings and critical conditions open their guidance, and
  runbook links remain visible. A severity change resets the disclosure safely.
- Destructive controls retain existing confirmation and step-up behavior.

## Acceptance and evidence

`clients/web/e2e/reference-ui.spec.ts` covers rendered member and administrative
screens at 390 and 1440 pixels in both themes, plus 320/1024 reflow. It checks
page containment, loading/error expectations, WCAG A/AA rules without disabled
checks, safe file filtering, and settings keyboard behavior. Optional
`K_COMMS_VISUAL_CAPTURE=1` emits per-screen PNG evidence into the chosen
Playwright output directory. Fixtures are synthetic and never contact production.

Existing accessibility, guest, instant-room, mobile-call, member-IA, immersive,
whiteboard, release-gate, unit, lint, type and production-build checks remain
required. Screenshots are reviewed in addition to automated layout assertions;
they do not prove real-device media quality or live production acceptance.

Release follows the [completion standard](../14-operations/development-to-production-completion-standard.md):
protected PR and checks, merge, one immutable artifact, synthetic staging,
independent production approval, backup and same-digest deployment. Rollback
uses the previous approved image; no data migration or preference reset is needed.

## Reference sources

- [Slack features](https://slack.com/features): channels, messaging, huddles,
  collaboration and search.
- [Microsoft Teams](https://www.microsoft.com/en-us/microsoft-teams/group-chat-software):
  business chat, meetings, files and administration.
- [WhatsApp messaging](https://www.whatsapp.com/messaging?lang=en) and
  [calling](https://www.whatsapp.com/calling): direct mobile communication.
- [Zoom collaboration tools](https://www.zoom.com/en/products/collaboration-tools/):
  meeting, chat, call and whiteboard workflows.
- [Mattermost platform](https://mattermost.com/platform-overview/): private
  enterprise communication and operational control.
