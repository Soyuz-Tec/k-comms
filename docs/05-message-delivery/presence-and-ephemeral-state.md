# Presence and Ephemeral State

Presence, typing, and temporary call signaling may be held in process memory and distributed through PubSub, provided that:

- State expires without explicit disconnect.
- Node loss does not corrupt durable data.
- Clients tolerate stale or missing values.
- Presence is not used to claim message delivery.
- Metadata is minimized to avoid privacy leakage.
- Large-room presence has a separate fan-out budget or summarized mode.
