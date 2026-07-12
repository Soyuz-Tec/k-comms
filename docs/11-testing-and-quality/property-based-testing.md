# Property-based Testing

Priority properties:

- Replaying the same command key never creates a second message.
- Applied conversation sequences never move backward.
- Events from another tenant never authorize or mutate the current tenant.
- Edit/delete state reduces deterministically from an event history.
- Retry schedules remain bounded and monotonic.
- Cursor pagination returns no gaps or duplicates beyond documented at-least-once replay.
