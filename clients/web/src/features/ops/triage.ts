import type { OperationsSnapshot } from "../../types";

export type OperationsTriageSeverity = "healthy" | "warning" | "critical";

export interface OperationsTriageItem {
  id: string;
  title: string;
  severity: OperationsTriageSeverity;
  condition: string;
  userImpact: string;
  owner: string;
  firstAction: string;
  stopCondition: string;
  escalation: string;
  runbookUrl: string | null;
}

const runbookRepository = "https://github.com/Soyuz-Tec/k-comms/blob";
const healthyProviderStates = new Set(["available", "configured", "healthy", "ok", "ready"]);
const activeQueueStates = new Set(["available", "executing", "retryable", "scheduled"]);

export function deriveOperationsTriage(
  snapshot: OperationsSnapshot,
  nowMilliseconds = Date.now()
): OperationsTriageItem[] {
  const generatedAt = Date.parse(snapshot.generated_at);
  const futureSkewSeconds = Number.isFinite(generatedAt)
    ? Math.round((generatedAt - nowMilliseconds) / 1_000)
    : Number.POSITIVE_INFINITY;
  const ageSeconds = Number.isFinite(generatedAt)
    ? Math.max(0, Math.round((nowMilliseconds - generatedAt) / 1_000))
    : Number.POSITIVE_INFINITY;
  const snapshotTimeInvalid = !Number.isFinite(generatedAt) || futureSkewSeconds > 30;
  const snapshotStale = snapshotTimeInvalid || ageSeconds > 120;
  const runbookBase = revisionBoundRunbookBase(snapshot.release_revision);

  const databaseState = normalizedState(snapshot.database?.status);
  const databaseHealthy = healthyProviderStates.has(databaseState);

  const activeQueues = snapshot.queues.filter(({ state }) => activeQueueStates.has(normalizedState(state)));
  const queuedJobs = activeQueues.reduce((sum, { count }) => sum + count, 0);
  const oldestQueueAgeSeconds = activeQueues.reduce((oldest, queue) => {
    const scheduledAt = queue.oldest_scheduled_at ? Date.parse(queue.oldest_scheduled_at) : Number.NaN;
    if (!Number.isFinite(scheduledAt)) return oldest;
    return Math.max(oldest, Math.max(0, Math.round((nowMilliseconds - scheduledAt) / 1_000)));
  }, 0);
  const durableWorkCritical = snapshot.outbox.pending > 1_000 || oldestQueueAgeSeconds > 900;
  const durableWorkWarning = snapshot.outbox.pending > 100 || oldestQueueAgeSeconds > 300;

  const deliveryFailures =
    failedCount(snapshot.notifications) + failedCount(snapshot.webhooks);
  const attachmentFailures = failedCount(snapshot.attachments);
  const providerEntries = Object.entries(snapshot.providers);
  const unavailableProviders = providerEntries
    .filter(([, value]) => !healthyProviderStates.has(providerState(value)))
    .map(([name]) => humanize(name));
  const testOnlyProviders = providerEntries
    .filter(([, value]) => typeof value !== "string" && value.test_only === true)
    .map(([name]) => humanize(name));

  return [
    {
      id: "snapshot-freshness",
      title: "Operations evidence freshness",
      severity: snapshotStale ? "warning" : "healthy",
      condition: snapshotTimeInvalid
        ? Number.isFinite(futureSkewSeconds)
          ? `The content-blind snapshot timestamp is ${futureSkewSeconds} seconds ahead of the operator clock.`
          : "The content-blind snapshot timestamp is invalid."
        : snapshotStale
          ? `The content-blind snapshot is ${ageSeconds} seconds old.`
          : `The content-blind snapshot is current (${ageSeconds} seconds old).`,
      userImpact: "Stale evidence can hide a new service or provider condition from operators.",
      owner: "Platform on-call",
      firstAction: "Refresh once and confirm the readiness and metrics paths are updating.",
      stopCondition: "Do not make a production change from stale or time-invalid evidence.",
      escalation: "Escalate to the observability owner if two refreshes remain stale.",
      runbookUrl: runbookLink(runbookBase, "service-degradation.md")
    },
    {
      id: "database",
      title: "Authoritative database",
      severity: databaseHealthy ? "healthy" : "critical",
      condition: databaseHealthy
        ? `The database probe reports ${databaseState}.`
        : `The database probe reports ${databaseState || "an unknown state"}.`,
      userImpact: "An unavailable authoritative database can stop authentication, reads, sends, and durable acknowledgements.",
      owner: "Database on-call",
      firstAction: "Confirm the current primary, replica, connection, and recent-change state from approved provider telemetry.",
      stopCondition: "Do not initiate failover while primary authority, replication safety, or the approved recovery point is unknown.",
      escalation: "Page the incident commander and database provider for an unavailable probe.",
      runbookUrl: runbookLink(runbookBase, "database-failover.md")
    },
    {
      id: "durable-work",
      title: "Queue and outbox delay",
      severity: durableWorkCritical ? "critical" : durableWorkWarning ? "warning" : "healthy",
      condition: `${queuedJobs} active queue jobs; oldest is ${oldestQueueAgeSeconds} seconds; ${snapshot.outbox.pending} outbox events pending.`,
      userImpact: "Durable messages remain stored, but notifications, scans, webhooks, and live fan-out may be delayed.",
      owner: "Application on-call",
      firstAction: "Check worker readiness, queue age by queue, outbox movement, and the most recent deployment before changing concurrency.",
      stopCondition: "Do not delete jobs, outbox events, or acknowledgement records to reduce the counters.",
      escalation: "Escalate when age grows for two intervals, outbox pending exceeds 1,000, or a user commitment is at risk.",
      runbookUrl: runbookLink(runbookBase, "queue-backlog.md")
    },
    {
      id: "delivery-providers",
      title: "Notification and webhook delivery",
      severity: unavailableProviders.length > 0 ? "critical" : deliveryFailures > 0 || testOnlyProviders.length > 0 ? "warning" : "healthy",
      condition: providerCondition(deliveryFailures, unavailableProviders, testOnlyProviders),
      userImpact: "Messages remain durable, but email, push, or webhook consumers may receive updates late or not at all.",
      owner: "Provider on-call",
      firstAction: "Confirm provider health, delivery backlog, retry movement, credentials, egress, and the last successful synthetic delivery.",
      stopCondition: "Do not replay deliveries until idempotency, provider recovery, and the retry rate are confirmed.",
      escalation: "Escalate to the provider owner and incident commander when delivery commitments or multiple tenants are affected.",
      runbookUrl: runbookLink(runbookBase, "queue-backlog.md")
    },
    {
      id: "attachment-safety",
      title: "Attachment safety pipeline",
      severity: attachmentFailures > 0 ? "warning" : "healthy",
      condition: attachmentFailures > 0
        ? `${attachmentFailures} attachment scan records are failed or dead-lettered.`
        : "No failed or dead-lettered attachment scan records are visible.",
      userImpact: "Affected files stay unavailable or quarantined while ordinary text communication continues.",
      owner: "Storage and safety on-call",
      firstAction: "Confirm scanner and object-storage health, then inspect content-free attempt codes and queue movement.",
      stopCondition: "Never bypass quarantine or mark an object clean without an approved scanner result bound to the exact object version.",
      escalation: "Escalate to the malware-scanner or object-storage owner when retries cannot safely progress.",
      runbookUrl: runbookLink(runbookBase, "object-storage-failure.md")
    }
  ];
}

function revisionBoundRunbookBase(revision: string) {
  const normalized = revision.trim().toLowerCase();
  return /^[0-9a-f]{40}$/.test(normalized)
    ? `${runbookRepository}/${normalized}/docs/08-reliability/runbooks`
    : null;
}

function runbookLink(base: string | null, fileName: string) {
  return base ? `${base}/${fileName}` : null;
}

function failedCount(values: Record<string, number>) {
  return Object.entries(values).reduce((total, [status, count]) =>
    ["dead_letter", "discarded", "failed"].includes(normalizedState(status)) ? total + count : total, 0);
}

function providerState(value: OperationsSnapshot["providers"][string]) {
  return normalizedState(typeof value === "string" ? value : value.status || value.reason || "unknown");
}

function normalizedState(value: string | null | undefined) {
  return (value || "").trim().toLowerCase().replaceAll("-", "_");
}

function providerCondition(failures: number, unavailable: string[], testOnly: string[]) {
  const parts = [`${failures} failed or dead-lettered deliveries`];
  if (unavailable.length > 0) parts.push(`providers needing attention: ${unavailable.join(", ")}`);
  if (testOnly.length > 0) parts.push(`test-only providers: ${testOnly.join(", ")}`);
  return `${parts.join("; ")}.`;
}

function humanize(value: string) {
  return value.replaceAll("_", " ");
}
