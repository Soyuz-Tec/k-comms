# Workload Model

Model at least these workloads independently:

1. Normal direct and small-group messaging.
2. Large channel with bursty fan-out.
3. Reconnect storm after network or deployment interruption.
4. Notification burst caused by mentions or announcements.
5. Attachment upload and processing spike.
6. Search indexing backlog and catch-up.
7. Tenant import or retention deletion.
8. Hot conversation with serialized sequence writes.

For each workload, record arrival distribution, payload size, recipient distribution, read/write ratio, cache hit expectations, acceptable degradation, and abort thresholds.
