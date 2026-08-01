import { describe, expect, it } from "vitest";
import type { WhiteboardElementData, WhiteboardOperation } from "../../types";
import {
  applyWhiteboardOperations,
  changedElements,
  noteRevisions,
  replayWhiteboardOperations
} from "./sceneModel";

describe("whiteboard scene replay", () => {
  it("replays in sequence order and resets at the latest clear", () => {
    const oldElement = element("old-element", 1, 90);
    const newElement = element("new-element", 1, 80);

    const scene = applyWhiteboardOperations([
      operation(3, "scene.update", [newElement]),
      operation(1, "scene.update", [oldElement]),
      operation(2, "board.clear")
    ]);

    expect(Array.from(scene.keys())).toEqual(["new-element"]);
  });

  it("matches Excalidraw equal-version nonce conflict resolution", () => {
    const local = element("shared-element", 4, 900);
    const remoteWinner = element("shared-element", 4, 100);
    const stale = element("shared-element", 3, 1);

    const scene = applyWhiteboardOperations([
      operation(1, "scene.update", [local]),
      operation(2, "scene.update", [stale]),
      operation(3, "scene.update", [remoteWinner])
    ]);

    expect(scene.get("shared-element")?.versionNonce).toBe(100);
  });

  it("sends only element revisions not already committed", () => {
    const revisions = new Map<string, string>();
    const original = element("shared-element", 1, 10);
    noteRevisions(revisions, [original]);

    expect(changedElements([original], revisions)).toEqual([]);

    const edited = { ...original, version: 2, versionNonce: 20 };
    expect(changedElements([edited], revisions)).toEqual([edited]);
  });

  it("retains cleared revisions while replaying from an already rendered scene", () => {
    const erased = element("erased-element", 8, 900);
    const replacement = element("replacement-element", 1, 100);

    const replay = replayWhiteboardOperations(
      [operation(2, "board.clear"), operation(3, "scene.update", [replacement])],
      new Map([[erased.id, erased]])
    );

    expect(replay.latestSequence).toBe(3);
    expect(replay.includesClear).toBe(true);
    expect(replay.clearedElements).toEqual([erased]);
    expect(Array.from(replay.scene.values())).toEqual([replacement]);
  });

  it("does not tombstone an element accepted in the post-clear generation", () => {
    const reused = element("reused-element", 4, 400);

    const replay = replayWhiteboardOperations(
      [operation(2, "board.clear"), operation(3, "scene.update", [reused])],
      new Map([[reused.id, reused]])
    );

    expect(replay.clearedElements).toEqual([]);
    expect(Array.from(replay.scene.values())).toEqual([reused]);
  });
});

function operation(
  sequence: number,
  kind: WhiteboardOperation["kind"],
  elements: WhiteboardElementData[] = []
): WhiteboardOperation {
  return {
    id: `operation-${sequence}`,
    whiteboard_id: "whiteboard-1",
    tenant_id: "tenant-1",
    conversation_id: "conversation-1",
    actor_user_id: "user-1",
    client_operation_id: `client-operation-${sequence}`,
    sequence,
    kind,
    payload: kind === "scene.update" ? { elements } : {},
    inserted_at: "2026-08-01T00:00:00Z"
  };
}

function element(
  id: string,
  version: number,
  versionNonce: number
): WhiteboardElementData {
  return {
    id,
    type: "rectangle",
    version,
    versionNonce,
    isDeleted: false
  };
}
