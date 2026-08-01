import { describe, expect, it } from "vitest";
import type { WhiteboardOperation } from "../../types";
import { orderWhiteboardOperations } from "./operationStream";

describe("whiteboard operation stream", () => {
  it("buffers an out-of-order update until the missing sequence arrives", () => {
    const queued = new Map<number, WhiteboardOperation>();

    const gap = orderWhiteboardOperations(1, queued, [operation(3)]);
    expect(gap.ready).toEqual([]);
    expect(gap.latestSequence).toBe(1);
    expect(gap.hasGap).toBe(true);

    const closed = orderWhiteboardOperations(1, queued, [operation(2)]);
    expect(closed.ready.map((item) => item.sequence)).toEqual([2, 3]);
    expect(closed.latestSequence).toBe(3);
    expect(closed.hasGap).toBe(false);
  });

  it("fast-forwards across compacted history when an authoritative clear arrives", () => {
    const queued = new Map<number, WhiteboardOperation>();

    const result = orderWhiteboardOperations(1, queued, [
      operation(6),
      operation(5, "board.clear")
    ]);

    expect(result.ready.map((item) => [item.sequence, item.kind])).toEqual([
      [5, "board.clear"],
      [6, "scene.update"]
    ]);
    expect(result.latestSequence).toBe(6);
    expect(result.hasGap).toBe(false);
  });

  it("ignores operations already applied to the stream", () => {
    const queued = new Map<number, WhiteboardOperation>();

    const result = orderWhiteboardOperations(4, queued, [operation(3), operation(4)]);

    expect(result.ready).toEqual([]);
    expect(result.latestSequence).toBe(4);
    expect(result.hasGap).toBe(false);
  });
});

function operation(
  sequence: number,
  kind: WhiteboardOperation["kind"] = "scene.update"
): WhiteboardOperation {
  return {
    id: `operation-${sequence}`,
    whiteboard_id: "whiteboard-one",
    tenant_id: "tenant-one",
    conversation_id: "conversation-one",
    actor_user_id: "user-one",
    client_operation_id: `client-operation-${sequence}`,
    sequence,
    kind,
    payload: kind === "scene.update" ? { elements: [] } : {},
    inserted_at: "2026-08-01T12:00:00Z"
  };
}
