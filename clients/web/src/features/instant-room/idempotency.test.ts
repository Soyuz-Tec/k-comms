import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  beginNewInstantRoomVisit,
  instantRoomIdempotencyKey,
  instantRoomJoinIdempotencyKey,
  newInstantRoomIdempotencyKey,
  rotateInstantRoomJoinIdempotencyKey
} from "./idempotency";

describe("instant-room idempotency keys", () => {
  beforeEach(() => {
    window.sessionStorage.clear();
    vi.restoreAllMocks();
  });

  it("creates a URL-safe 256-bit key and reuses it in the same tab", () => {
    const first = instantRoomIdempotencyKey();
    const second = instantRoomIdempotencyKey();

    expect(first).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(second).toBe(first);
  });

  it("does not reuse malformed session storage", () => {
    window.sessionStorage.setItem(
      "k-comms.instant-room.idempotency.v1",
      "predictable"
    );

    expect(instantRoomIdempotencyKey()).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(instantRoomIdempotencyKey()).not.toBe("predictable");
  });

  it("can explicitly begin a new one-click room visit", () => {
    const original = instantRoomIdempotencyKey();
    const next = beginNewInstantRoomVisit();

    expect(next).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(next).not.toBe(original);
    expect(instantRoomIdempotencyKey()).toBe(next);
  });

  it("draws all 32 bytes from Web Crypto", () => {
    const getRandomValues = vi.spyOn(globalThis.crypto, "getRandomValues");

    newInstantRoomIdempotencyKey();

    expect(getRandomValues).toHaveBeenCalledWith(
      expect.objectContaining({ byteLength: 32 })
    );
  });

  it("persists a join key by token digest and account mode without storing the token", async () => {
    const first = await instantRoomJoinIdempotencyKey(
      "secret-fragment-token",
      "guest"
    );
    const replay = await instantRoomJoinIdempotencyKey(
      "secret-fragment-token",
      "guest"
    );
    const accountAttempt = await instantRoomJoinIdempotencyKey(
      "secret-fragment-token",
      "account"
    );
    const stored =
      window.sessionStorage.getItem(
        "k-comms.instant-room.join-idempotency.v1"
      ) || "";

    expect(first).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(replay).toBe(first);
    expect(accountAttempt).not.toBe(first);
    expect(stored).not.toContain("secret-fragment-token");
  });

  it("rotates a join key only when the caller explicitly recovers an expired replay", async () => {
    const original = await instantRoomJoinIdempotencyKey(
      "secret-fragment-token",
      "guest"
    );
    const rotated = await rotateInstantRoomJoinIdempotencyKey(
      "secret-fragment-token",
      "guest"
    );

    expect(rotated).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(rotated).not.toBe(original);
    expect(
      await instantRoomJoinIdempotencyKey("secret-fragment-token", "guest")
    ).toBe(rotated);
  });
});
