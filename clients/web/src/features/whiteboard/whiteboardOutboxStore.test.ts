import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  clearWhiteboardOutbox,
  loadWhiteboardOutbox,
  saveWhiteboardOutbox,
  type WhiteboardOutboxEntry
} from "./whiteboardOutboxStore";

const entry: WhiteboardOutboxEntry = {
  id: "operation-123456",
  baseSequence: 4,
  createdAt: "2026-09-06T12:00:00.000Z",
  elements: [
    {
      id: "rectangle-123456",
      type: "rectangle",
      version: 2,
      versionNonce: 8,
      isDeleted: false,
      link: null,
      customData: null
    }
  ]
};

describe("whiteboard outbox store", () => {
  const originalIndexedDb = globalThis.indexedDB;

  beforeEach(() => {
    window.localStorage.clear();
    Object.defineProperty(globalThis, "indexedDB", {
      configurable: true,
      value: undefined
    });
  });

  afterEach(() => {
    Object.defineProperty(globalThis, "indexedDB", {
      configurable: true,
      value: originalIndexedDb
    });
  });

  it("round-trips pending edits through the browser fallback", async () => {
    await saveWhiteboardOutbox("test-board", [entry]);

    await expect(loadWhiteboardOutbox("test-board")).resolves.toEqual([entry]);
  });

  it("clears pending edits after an acknowledgement", async () => {
    await saveWhiteboardOutbox("test-board", [entry]);
    await clearWhiteboardOutbox("test-board", [entry.id]);

    await expect(loadWhiteboardOutbox("test-board")).resolves.toEqual([]);
  });

  it("drops malformed or unsupported entries before replay", async () => {
    await saveWhiteboardOutbox("test-board", [entry]);
    window.localStorage.setItem(
      "k-comms.whiteboard-outbox.v1:test-board:" + entry.id,
      JSON.stringify({ ...entry, elements: [{ ...entry.elements[0], type: "image" }] })
    );

    await expect(loadWhiteboardOutbox("test-board")).resolves.toEqual([]);
  });

  it("acknowledges one tab's operation without erasing another tab's edits", async () => {
    const other = { ...entry, id: "operation-other-tab" };
    await saveWhiteboardOutbox("test-board", [entry]);
    await saveWhiteboardOutbox("test-board", [other]);
    await clearWhiteboardOutbox("test-board", [entry.id]);
    await expect(loadWhiteboardOutbox("test-board")).resolves.toEqual([other]);
    await expect(loadWhiteboardOutbox("different-user")).resolves.toEqual([]);
  });
});
