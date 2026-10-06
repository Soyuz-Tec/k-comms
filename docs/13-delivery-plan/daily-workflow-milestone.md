# Daily workflow milestone

This milestone closes the first set of competitive UI gaps in the existing
calm enterprise desktop shell. It covers protecting unfinished work, finding
and resuming conversations, scheduling and joining meetings, returning calls,
and changing personal availability. It does not establish full UC parity or
production qualification by itself.

## Acceptance criteria

| Journey | Required behavior |
|---|---|
| Leave a document with pending edits | In-app links, document switching, and browser history preserve the editor until the user stays or explicitly discards unsent work. Browser reload keeps its native warning. Permission loss still clears protected state immediately. |
| Leave a private-room draft or unfinished recovery | Navigation explains what will be lost and offers a safe stay action. Private plaintext and recovery keys are not copied into ordinary persistent draft storage. Revocation and session replacement close the private runtime. |
| Start private-room setup | Check the deployment capability and browser prerequisites before local setup. Unknown, unavailable, and failed states give truthful guidance and retry. Configuration availability never claims successful provider or crypto qualification. |
| Triage Inbox | Authorized recent-message/sender and own-draft previews make rows useful. Favorites persist per membership. Delayed responses cannot restore excerpts from an earlier identity or revoked access. |
| Find and return an Internet call | Recent history is useful on entry. Person, conversation and date filters apply to the authorized retained history. Recipient lookup clearly starts Internet calls. |
| Plan and join a meeting | The upcoming agenda continues across month boundaries. Scheduling, joining and sharing distinguish conversation access, personal calendar copies and invitations; lobby and device checks stay enforced. |
| Return a phone call or voicemail | Search retained phone history by supported number/date/direction filters. Accept explicitly international formatted numbers without guessing a country. Voicemail identifies an authorized caller and prepares a callback for deliberate dialing. |
| Change availability | A compact account control exposes current status and expiring DND, with save failures, retry and clearing. The mobile You surface exposes the same server-owned state. |

The phone directory currently has no general person-to-PSTN mapping. Internet
recipient lookup must not be labeled as carrier directory dialing. Phone
callbacks still require an assigned line and the existing provider/media gates.

## Verification and release gates

Use behavior tests for the changed contracts and negative authorization paths,
then exercise the rendered application with realistic synthetic records. Check
keyboard operation, accessible names and focus, error/empty/loading states,
narrow layouts, and browser Back/Forward. Capture source-bound desktop and
mobile screens. Synthetic browser checks and automated accessibility scans do
not replace physical-device or screen-reader testing.

Run the applicable backend, web, contract, architecture, documentation and
security gates. Keep current asset budgets enforced. Follow the
[development-to-production completion standard](../14-operations/development-to-production-completion-standard.md)
through protected checks and source delivery. Record exact revisions, test
counts, immutable artifact identity and deployment receipts in the delivery
record, rather than embedding changing counts here.

The favorite preference adds a boolean with a false default to conversation
membership. Older clients can ignore additive response fields, and the prior
application can run with the additive column retained. Roll back the application
to the recorded prior digest if needed; do not drop user preferences as a routine
application rollback. New filters preserve existing default request behavior.

Staging VM 101 is intentionally offline. Deployment and staging backup,
rollback, restore and runtime qualification remain pending until it is available.
No carrier/DID has been supplied. Real telephony, calendar-provider behavior,
Matrix device/recovery and native-device qualification remain independent gates.
No change in this milestone authorizes bypassing those gates or claiming a
production release.

## Human usability acceptance

Use the same records, starting points, device class and task instructions for
K-Comms and the selected comparable product/edition. Ask participants to find
an unread conversation, resume a draft, set timed DND, schedule and share a
meeting, return a missed call, and recover from a failed save without losing work.
Record unaided completion, time, actions, errors and task-ease ratings. Include
keyboard and assistive-technology users.

Targets are at least 90% unaided success on critical tasks, median time/actions
within 20% of a matched reference workflow, task ease of at least 6/7 and SUS of
at least 80. These are acceptance targets, not results from automated tests or
screen captures. Report observed sample size and limitations before drawing
competitive conclusions.
