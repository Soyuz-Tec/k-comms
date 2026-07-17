# Event Catalog

| Event type | Durable | Ordered scope | Typical consumers |
|---|---:|---|---|
| `message.created.v1` | Yes | Conversation | Clients, search, notifications, webhooks |
| `mention.created.v1` | Yes | Message | Human-recipient notification fanout; IDs only, no body |
| `message.updated.v1` | Yes | Conversation | Clients, search, audit |
| `message.deleted.v1` | Yes | Conversation | Clients, search, retention |
| `message.reaction_added.v1` | No | Conversation | Connected clients |
| `message.reaction_removed.v1` | No | Conversation | Connected clients |
| `conversation.created.v1` | Yes | Conversation | Audit and future projections |
| `membership.changed.v1` | Yes | Conversation | Clients, authorization, audit; content-free administrative and self-service membership deltas |
| `conversation.read.v1` | No | User/conversation | Connected clients, unread projections |
| `call.started.v1` | Yes | Conversation | Clients refresh active-call state; content-free ID, conversation ID, media kind, status, and lifecycle times only |
| `call.ended.v1` | Yes | Conversation | Clients detach media and refresh active-call state; includes media kind and lifecycle metadata, never provider data |
| `presence_state` / `presence_diff` | No | Topic | Connected clients |
| `typing.start` / `typing.stop` | No | Topic | Connected clients |
| `notification.available.v1` | No | User | Content-free notification-center refresh |

Durable message events are written to the transactional outbox. The AsyncAPI
contract is canonical for client-visible payloads; durable event types require
schema compatibility review before change.

Call events use the same tenant/conversation authorization and outbox boundary.
Both event payloads include `media_kind: "audio" | "video"`. They must not
include participant tokens, provider rooms or identities, device names, SDP,
ICE, media tracks, camera/screen state, or quality telemetry.
