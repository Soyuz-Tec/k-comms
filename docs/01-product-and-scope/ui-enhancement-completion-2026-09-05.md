# UI enhancement acceptance

Status: Implementation and release acceptance contract

Scope: Findings verified against release `112aac9cfcf6459dbd5a351434d86d7492c7113b`,
plus the requested reduction of the whiteboard header and status area.

## User outcomes

| Area | Required outcome | Evidence |
| --- | --- | --- |
| Governance | Retention creation explains whole-workspace scope, period, immediate activation and eligible deletion before confirmation. Attachment deletion is opt-in. Approval identifies the actual deletion target and consequences. | Component tests cover cancellation, payload, explicit confirmation and target identity; existing backend authorization, audit, step-up and holds remain authoritative. |
| Notifications | Every unread item is reachable, including one older than 50 newer read items. Pagination preserves tenant and user scope. | Backend/API and component tests cover bounded cursors, unread filtering, pagination and stale responses. |
| Notification presentation | Unread state is restrained; the panel clearly isolates background navigation, with visible dismissal and loading/error controls. | Phone/desktop light/dark renders and focus tests. |
| Narrow screens | Filenames and file actions do not overlap; the selected call media label fits. | Element geometry checks at 320/390/1024/1440 pixels in light and dark. |
| Administration | Phone people records expose role, status and session actions without sideways scrolling. Summary statistics remain compact. | Role/session tests and rendered geometry/focus checks. |
| Operations | Healthy conditions occupy compact rows; warnings and stale evidence expand guidance. Conditions and release-bound runbooks remain available. | Severity lifecycle tests and rendered healthy/degraded states. |
| Navigation and files | Compact member titles identify their local controls. Wide file lists provide better column allocation and named actions. | Rendered heading/list checks and existing navigation tests. |
| Calls and guest rooms | Prejoin describes the selected call type without implying camera consent. Disabled guest calls explain room capability without dominating chat. | Consent tests and guest/prejoin renders. |
| Room setup | Step wording matches the setup task; required/optional labels are separated. | Draft continuity and room creation tests. |
| Whiteboard space | The standalone board combines identity, status and conversation controls in one desktop strip, with a compact second status line on phones. | Header is at most 60 CSS pixels on desktop and 80 on phones, without hiding save or connection state. |

## Decisions and boundaries

The existing last-workspace sign-in convenience remains in place. No new
workspace discovery or identity lookup is introduced. The intentional compact
desktop rail remains unchanged. Canvas templates reuse the existing gallery and
never replace existing drawings. Camera and microphone still require explicit
consent. Guest controls do not widen room capabilities.

Notification pagination is an additive API change documented by ADR-0076 and
the mirrored OpenAPI contracts. No data migration, storage ownership change,
provider enablement or new service is required. Existing notification read and
dismiss semantics remain durable and authorized.

The prior screenshot README's pending-production paragraph was a historical
handoff state, superseded by the successful production release receipt. New
evidence must identify its own revision and distinguish synthetic browser checks
from public endpoint checks and real-device media qualification.

## Release and rollback

Apply the [completion standard](../14-operations/development-to-production-completion-standard.md).
Publish one immutable image, qualify it in staging, and promote that same digest
through the independently approved production environment. Retain backup,
rollback, reconciliation and public health evidence. Do not enable providers or
alter existing production retention policies as part of this UI release.

Rollback uses the previous qualified immutable image. Existing clients remain
compatible with additive notification response fields and default All behavior.
No generated screenshots, runtime receipts, local databases or credentials belong
in the source change.
