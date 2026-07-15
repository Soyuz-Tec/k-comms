import { describe, expect, it } from "vitest";
import type { OperationsSnapshot } from "../../types";
import { deriveOperationsTriage } from "./triage";

const now = Date.parse("2026-07-14T12:00:00Z");

describe("deriveOperationsTriage", () => {
  it("makes healthy platform evidence actionable without inventing incidents", () => {
    const items = deriveOperationsTriage(snapshot(), now);

    expect(items).toHaveLength(5);
    expect(items.every(({ severity }) => severity === "healthy")).toBe(true);
    expect(items.every(({ owner, firstAction, stopCondition, escalation, runbookUrl }) =>
      Boolean(owner && firstAction && stopCondition && escalation && runbookUrl?.includes("a".repeat(40))))).toBe(true);
  });

  it("classifies stale, database, backlog, provider, and scan conditions", () => {
    const input = snapshot();
    input.generated_at = "2026-07-14T11:50:00Z";
    input.database = { status: "unavailable" };
    input.outbox.pending = 1_001;
    input.queues = [{ queue: "events", state: "retryable", count: 12, oldest_scheduled_at: "2026-07-14T11:40:00Z" }];
    input.notifications = { failed: 2 };
    input.attachments = { dead_letter: 1 };
    input.providers = {
      notifications: { status: "degraded" },
      attachment_scanner: { status: "ready", test_only: true }
    };

    const byId = Object.fromEntries(deriveOperationsTriage(input, now).map((item) => [item.id, item]));
    expect(byId["snapshot-freshness"]?.severity).toBe("warning");
    expect(byId.database?.severity).toBe("critical");
    expect(byId["durable-work"]?.severity).toBe("critical");
    expect(byId["delivery-providers"]?.severity).toBe("critical");
    expect(byId["attachment-safety"]?.severity).toBe("warning");
  });

  it("rejects future-dated evidence and mutable runbook links", () => {
    const input = snapshot();
    input.generated_at = "2026-07-14T12:05:00Z";
    input.release_revision = "development";

    const items = deriveOperationsTriage(input, now);
    expect(items[0]?.severity).toBe("warning");
    expect(items[0]?.condition).toContain("ahead of the operator clock");
    expect(items.every(({ runbookUrl }) => runbookUrl === null)).toBe(true);
  });
});

function snapshot(): OperationsSnapshot {
  return {
    generated_at: "2026-07-14T11:59:30Z",
    release_revision: "a".repeat(40),
    database: { status: "ready" },
    queues: [],
    outbox: { pending: 0, published: 12 },
    notifications: {},
    webhooks: {},
    attachments: {},
    providers: {
      notifications: { status: "ready" },
      webhooks: { status: "available" },
      attachment_scanner: { status: "configured" }
    }
  };
}
