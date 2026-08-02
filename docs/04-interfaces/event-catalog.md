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
| `whiteboard.operation_applied.v1` | Yes | Conversation whiteboard | Active workspace members and exact-room instant participants; clients reconcile durable history over authorized member or guest REST after gaps |
| `whiteboard.presence.v1` | No | User/conversation whiteboard | Other currently authorized workspace members or exact-room instant participants; bounded pointer and selection state only |
| `call.started.v1` | Yes | Conversation | Clients refresh active-call state; content-free ID, conversation ID, media kind, status, and lifecycle times only |
| `call.ended.v1` | Yes | Conversation | Clients detach media and refresh active-call state; includes media kind and lifecycle metadata, never provider data |
| `ephemeral_room.created.v1` / `ephemeral_room.reactivated.v1` | Yes | Instant room | Audit, operations, and authorized outbox consumers; not a client conversation-channel event |
| `ephemeral_room.idle.v1` / `ephemeral_room.expired.v1` | Yes | Instant room | Audit, lifecycle operations, and authorized outbox consumers; not a client conversation-channel event |
| `ephemeral_room.owner_upgraded.v1` | Yes | Instant room | Audit, identity/lifecycle operations, and authorized outbox consumers; not a client conversation-channel event |
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

Instant-room lifecycle evidence is durable Audit/Outbox data, not part of the
client-visible AsyncAPI conversation channel. Clients reconcile authorized room
state over REST; a socket event is never lifecycle authority.
