# Mobile PWA UI audit — 2026-08-09

## Scope and evidence

This audit rechecked the prior ten-item Windows mobile-format review before
implementation. Evidence came from the installed production PWA at
`comms.avayaworks.com`, its Windows UI Automation tree at approximately
513 by 734 CSS pixels, current `main` source and tests, the product interface
standard, the mobile delivery plan, and the install-scoped PWA ADR.

Production was behind current `main` during the audit. Deployed behavior was
therefore treated as runtime evidence, not as the implementation baseline.

## Revalidated findings

| # | Audit result | Refined improvement |
|---|---|---|
| 1 | Confirmed. The deployed document had minor outer vertical overflow, while tests checked horizontal overflow only. Current message sizing also stopped reserving the fixed bottom navigation. | Contain the chat shell to the dynamic viewport, reserve both fixed bars, keep scrolling inside the Inbox or message list, and add a vertical document-overflow assertion. |
| 2 | Confirmed at the observed 513 by 734 viewport. Shell, identity, actions, and section navigation consumed too much of the short view. | Use a single compact identity/action row from 380 CSS pixels upward while retaining the two-row fallback at 320 pixels. |
| 3 | The original proposal to replace audio and video with a call chooser was inaccurate. It would add a click and violate the approved one-action-to-lobby target. | Keep separate one-action audio and video buttons; compact their responsive placement without changing consent or lobby behavior. |
| 4 | Confirmed. `Live` described the realtime message connection and could be mistaken for an active call. | Label the healthy transport `Connected`; reserve active-call language for an actual joined call. |
| 5 | Confirmed. The empty state explained durability but did not offer a next action. | Add `Write first message` with focus transfer and direct audio/video lobby actions using the existing policy-aware launcher. |
| 6 | Confirmed. The recipient appeared in both the heading and placeholder, and a green check was visible even with no draft. | Render draft persistence only after non-whitespace input, use `Draft to …` on wider views, keep `Saved on this device` visible on mobile, and retain the recipient in the field placeholder and accessible label. |
| 7 | Partially confirmed. Unread counts already existed. Message previews, senders, and mentions are not part of the content-free Conversation projection and adding them would cross the ConversationContent privacy boundary. | Strengthen unread scanning with row state and explicit copy, show unambiguous update time, and surface only an existing joined-call state. Do not add message content to the conversation-list contract. |
| 8 | Confirmed. A funnel icon suggested filtering, but the control opened channel discovery. | Use a compass icon while preserving the accurate `Browse channels` accessible name. |
| 9 | Partially confirmed. Mixed element types reflected two route destinations and two modal panels, but the current Chat item was a non-interactive span. | Make Chat and Canvas route links, retain Activity and Details as disclosure buttons, and connect those buttons to their dialog IDs with `aria-controls`. |
| 10 | Valid only as progressive enhancement. Window Controls Overlay is desktop-only and not universally supported. | Prefer `window-controls-overlay` in `display_override`, retain standalone fallback, reserve the operating-system control area, and keep product controls non-draggable. |

## Further improvements found during re-audit

1. Add the exact observed 513 by 734 viewport to the automated phone matrix;
   the existing matrix covered 320, 390, and 700 CSS pixels only.
2. Treat the fixed bottom navigation as reserved viewport space on the message
   screen. A full-height message pane behind the navigation can hide composer
   controls even when the document itself appears nearly fitted.
3. Keep production/current-main drift explicit in UI audits. A protected
   release waiting for production approval can make deployed screenshots look
   older than the branch selected for remediation.
4. Window Controls Overlay requires an installed desktop PWA and remains a
   physical Chromium qualification item; automated manifest and fallback
   checks cannot prove operating-system chrome placement.
5. Wide installed windows use the desktop rail and do not render the compact
   top bar. They therefore need their own drag region and titlebar inset so
   Windows or macOS controls cannot obscure application content.

## Security and architecture decision

The implementation stays within the web client and existing call-session
owner. It does not add message content to Inbox summaries, change public APIs,
cache authenticated data, weaken media consent, or change authorization. The
PWA keeps standalone fallback and the existing network-only privacy boundary.
No new service or data-ownership ADR is required; ADR-0060 is updated for the
progressive display preference.

## Acceptance

- No outer document overflow on Inbox or conversation screens at 320 by 640,
  390 by 844, 513 by 734, and 700 by 900 CSS pixels.
- All call and message controls remain at least 44 by 44 CSS pixels.
- Audio and video each remain one action to their explicit-consent lobby.
- Empty-state actions, draft truthfulness, Inbox scan state, discovery icon,
  route/panel semantics, and manifest fallback are covered by automated tests.
- Installed desktop overlay geometry and physical iOS/Android install/update
  behavior remain release-device qualification gates.
