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
3. Start or join an authorized audio/video call, manage camera/microphone, see
   the participant grid, and share or stop sharing a screen.
4. Send a message and receive a durable acknowledgment.
5. Receive live events while connected.
6. Reconnect and recover all missed durable events.
7. Upload, scan, and share an attachment.
8. Search permitted history.
9. Manage membership, roles, retention, and moderation.
10. Integrate an external system through APIs or webhooks.

## Success conditions

- Acknowledged messages remain recoverable after application-node failure.
- Authorization is enforced at tenant, conversation, and operation levels.
- Clients can converge to authoritative conversation state after disconnection.
- Call admission follows current tenant/session/conversation authority, and
  media failure cannot make durable messaging unavailable.
- Operations can identify, contain, and recover from service degradation.
