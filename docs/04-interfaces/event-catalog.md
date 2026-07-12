# Event Catalog

| Event type | Durable | Ordered scope | Typical consumers |
|---|---:|---|---|
| `message.created.v1` | Yes | Conversation | Clients, search, notifications, webhooks |
| `message.updated.v1` | Yes | Conversation | Clients, search, audit |
| `message.deleted.v1` | Yes | Conversation | Clients, search, retention |
| `message.reaction_added.v1` | No | Conversation | Connected clients |
| `message.reaction_removed.v1` | No | Conversation | Connected clients |
| `conversation.created.v1` | Yes | Conversation | Audit and future projections |
| `membership.changed.v1` | Yes | Conversation | Clients, authorization, audit |
| `conversation.read.v1` | No | User/conversation | Connected clients, unread projections |
| `presence_state` / `presence_diff` | No | Topic | Connected clients |
| `typing.start` / `typing.stop` | No | Topic | Connected clients |

Durable message events are written to the transactional outbox. The AsyncAPI
contract is canonical for client-visible payloads; durable event types require
schema compatibility review before change.
