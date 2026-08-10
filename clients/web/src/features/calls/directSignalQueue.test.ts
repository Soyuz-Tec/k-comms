import { describe, expect, it } from "vitest";
import { DirectSignalQueue } from "./directSignalQueue";

describe("DirectSignalQueue", () => {
  it("rejects entries beyond the count boundary", () => {
    const queue = new DirectSignalQueue<{ id: number }>(2, 1_024, 15_000);

    expect(queue.enqueue({ id: 1 }, 1_000)).toBe(true);
    expect(queue.enqueue({ id: 2 }, 1_001)).toBe(true);
    expect(queue.enqueue({ id: 3 }, 1_002)).toBe(false);
    expect(queue.drain(1_003)).toEqual([{ id: 1 }, { id: 2 }]);
  });

  it("rejects a byte-budget overflow and resets accounting when cleared", () => {
    const queue = new DirectSignalQueue<{ value: string }>(32, 40, 15_000);

    expect(queue.enqueue({ value: "small" }, 1_000)).toBe(true);
    expect(queue.enqueue({ value: "this payload exceeds the remaining budget" }, 1_001)).toBe(false);
    expect(queue.size).toBe(1);
    expect(queue.bytes).toBeGreaterThan(0);

    queue.clear();
    expect(queue.size).toBe(0);
    expect(queue.bytes).toBe(0);
  });

  it("drops stale signals rather than replaying them after negotiation", () => {
    const queue = new DirectSignalQueue<{ id: number }>(32, 1_024, 15_000);

    expect(queue.enqueue({ id: 1 }, 1_000)).toBe(true);
    expect(queue.drain(16_001)).toEqual([]);
  });
});
