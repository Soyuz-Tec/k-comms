# Event Catalog

| Event type | Durable | Ordered scope | Typical consumers |
|---|---:|---|---|
| `message.created.v1` | Yes | Conversation | Clients, search, notifications, webhooks |
| `message.revised.v1` | Yes | Conversation | Clients, search, audit |
| `message.deleted.v1` | Yes | Conversation | Clients, search, retention |
| `reaction.changed.v1` | Yes | Conversation | Clients, projections |
| `membership.changed.v1` | Yes | Conversation | Clients, authorization caches |
| `read_cursor.advanced.v1` | Yes | User/conversation | Clients, unread projections |
| `presence.diff.v1` | No | Topic | Connected clients |
| `typing.changed.v1` | No | Topic | Connected clients |
| `attachment.ready.v1` | Yes | Attachment | Clients, message projection |

Each event must have a JSON schema, ownership, retention classification, compatibility policy, and representative examples.
