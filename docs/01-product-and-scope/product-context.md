# Product Context

**Status:** Draft

## Product statement

A secure, multi-tenant communication platform for direct messages, group conversations, channels, presence, files, notifications, administration, integrations, and durable message history.

## Primary actors

- End user
- Tenant administrator
- Moderator or compliance administrator
- Support operator
- Bot or service account
- External identity provider
- Push, email, webhook, and media providers

## Core product journeys

1. Join a tenant and authenticate a device.
2. Discover or create a conversation.
3. Send a message and receive a durable acknowledgment.
4. Receive live events while connected.
5. Reconnect and recover all missed durable events.
6. Upload, scan, and share an attachment.
7. Search permitted history.
8. Manage membership, roles, retention, and moderation.
9. Integrate an external system through APIs or webhooks.

## Success conditions

- Acknowledged messages remain recoverable after application-node failure.
- Authorization is enforced at tenant, conversation, and operation levels.
- Clients can converge to authoritative conversation state after disconnection.
- Operations can identify, contain, and recover from service degradation.
