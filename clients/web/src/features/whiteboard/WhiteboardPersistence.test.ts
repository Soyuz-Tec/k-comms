import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { WhiteboardElementData, WhiteboardOperation } from "../../types";
import { WhiteboardPersistence, type WhiteboardPersistenceDependencies } from "./WhiteboardPersistence";

const storage = vi.hoisted(() => new Map<string, unknown>());
vi.mock("./whiteboardOutboxStore", () => ({
  loadWhiteboardOutbox: vi.fn(async () => [...storage.values()]),
  saveWhiteboardOutbox: vi.fn(async (_key, entries) => {
    for (const entry of entries) storage.set(entry.id, structuredClone(entry));
    return true;
  }),
  clearWhiteboardOutbox: vi.fn(async (_key, ids) => {
    for (const id of ids) storage.delete(id);
  })
}));

function element(id = "rectangle-one", version = 1): WhiteboardElementData {
  return { id, type: "rectangle", version, versionNonce: version, isDeleted: false, link: null, customData: null };
}

function harness() {
  const dependencies: WhiteboardPersistenceDependencies = {
    api: {
      appendWhiteboardSceneUpdate: vi.fn(async (_conversation, id, base, elements) => ({
        id, kind: "scene.update", sequence: base + 1, payload: { elements }
      } as WhiteboardOperation)),
      clearWhiteboard: vi.fn(async () => ({
        kind: "board.clear", sequence: 10, payload: {}
      } as WhiteboardOperation))
    },
    conversationId: "conversation-one", outboxKey: "user-device-board",
    editor: { current: null }, applyingRemote: { current: false },
    scene: { current: new Map() }, latestSequence: { current: 0 },
    revisions: { current: new Map() }, clearedRevisions: { current: new Map() },
    acceptOperation: vi.fn(), onElementCount: vi.fn(), onSaveStatus: vi.fn(),
    onPendingChange: vi.fn(), onError: vi.fn(), onReplayRequested: vi.fn()
  };
  const persistence = new WhiteboardPersistence(dependencies);
  persistence.armLocalChanges();
  return { persistence, dependencies };
}

describe("whiteboard recovery lifecycle", () => {
  beforeEach(() => { storage.clear(); vi.useFakeTimers(); });
  afterEach(() => vi.useRealTimers());

  it("keeps an in-flight batch recoverable until acknowledgement without duplicate renders", async () => {
    const { persistence, dependencies } = harness();
    let acknowledge!: (operation: WhiteboardOperation) => void;
    vi.mocked(dependencies.api.appendWhiteboardSceneUpdate).mockImplementation(() =>
      new Promise((resolve) => { acknowledge = resolve; })
    );
    persistence.handleEditorChange([element()] as never);
    await vi.advanceTimersByTimeAsync(350);
    expect(storage.size).toBe(1);
    persistence.handleEditorChange([element()] as never);
    await vi.advanceTimersByTimeAsync(350);
    expect(dependencies.api.appendWhiteboardSceneUpdate).toHaveBeenCalledTimes(1);
    const call = vi.mocked(dependencies.api.appendWhiteboardSceneUpdate).mock.calls[0];
    if (!call) throw new Error("Expected a pending write");
    persistence.dispose();
    expect(storage.size).toBe(1);
    acknowledge({ id: call[1], kind: "scene.update", sequence: 1, payload: { elements: call[3] } } as WhiteboardOperation);
    await vi.advanceTimersByTimeAsync(0);
    expect(storage.size).toBe(0);
  });

  it("retries an uncertain request with identical identity and content while queuing newer edits", async () => {
    const { persistence, dependencies } = harness();
    vi.mocked(dependencies.api.appendWhiteboardSceneUpdate).mockRejectedValueOnce(new Error("Lost acknowledgement"));
    persistence.handleEditorChange([element()] as never);
    await vi.advanceTimersByTimeAsync(350);
    persistence.handleEditorChange([element("rectangle-one", 2)] as never);
    await vi.advanceTimersByTimeAsync(350);
    expect(storage.size).toBe(2);
    await vi.advanceTimersByTimeAsync(2_100);
    const calls = vi.mocked(dependencies.api.appendWhiteboardSceneUpdate).mock.calls;
    expect(calls).toHaveLength(3);
    expect(calls[1]).toEqual(calls[0]);
    expect(calls[2]?.[1]).not.toBe(calls[0]?.[1]);
    expect(calls[2]?.[3][0]?.version).toBe(2);
    expect(storage.size).toBe(0);
    persistence.dispose();
  });

  it("retains all pending work when a shared clear fails", async () => {
    const { persistence, dependencies } = harness();
    vi.mocked(dependencies.api.clearWhiteboard).mockRejectedValue(new Error("Offline"));
    persistence.handleEditorChange([element()] as never);
    await expect(persistence.clearBoard()).rejects.toThrow("Offline");
    expect(storage.size).toBe(1);
    expect(dependencies.scene.current.size).toBe(1);
    persistence.dispose();
  });

  it("bounds batches when pasting more than fifty objects", async () => {
    const { persistence, dependencies } = harness();
    persistence.handleEditorChange(Array.from({ length: 120 }, (_, id) => element("rectangle-" + id)) as never);
    await vi.advanceTimersByTimeAsync(400);
    const calls = vi.mocked(dependencies.api.appendWhiteboardSceneUpdate).mock.calls;
    expect(calls.map((call) => call[3].length)).toEqual([50, 50, 20]);
    expect(storage.size).toBe(0);
    persistence.dispose();
  });

  it("does not erase persisted recovery during mount cleanup or overwrite another tab", async () => {
    storage.set("existing-operation", { id: "existing-operation", baseSequence: 0, elements: [element()], createdAt: "2026-09-06T12:00:00Z" });
    const { persistence } = harness();
    persistence.dispose();
    expect(storage.size).toBe(1);
    const restored = await persistence.restoreOutbox();
    expect(restored[0]?.id).toBe("existing-operation");
  });

  it("rejects recovery from before a clear while retaining edits from the current generation", async () => {
    storage.set("old-operation", { id: "old-operation", baseSequence: 0, elements: [element()], createdAt: "2026-09-06T12:00:00Z" });
    storage.set("new-operation", { id: "new-operation", baseSequence: 5, elements: [element("new-rectangle")], createdAt: "2026-09-06T12:01:00Z" });
    const { persistence } = harness();
    await persistence.restoreOutbox();
    persistence.discardBeforeClear(5);
    expect((await persistence.restoreOutbox()).map((entry) => entry.id)).toEqual(["new-operation"]);
    await vi.advanceTimersByTimeAsync(0);
    expect(storage.has("old-operation")).toBe(false);
    persistence.dispose();
  });
});
