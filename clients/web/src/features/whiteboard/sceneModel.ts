import type {
  WhiteboardElementData,
  WhiteboardOperation
} from "../../types";

export type WhiteboardScene = Map<string, WhiteboardElementData>;

export type WhiteboardReplay = {
  scene: WhiteboardScene;
  latestSequence: number;
  clearedElements: WhiteboardElementData[];
  includesClear: boolean;
};

/**
 * Build a scene from a server snapshot.
 *
 * Insertion order is the paint order, and the server preserves it, so the map
 * is populated in the order given rather than sorted here.
 */
export function sceneFromElements(
  elements: readonly WhiteboardElementData[]
): WhiteboardScene {
  const scene: WhiteboardScene = new Map();
  for (const element of elements) {
    scene.set(element.id, element);
  }
  return scene;
}

export function applyWhiteboardOperation(
  scene: WhiteboardScene,
  operation: WhiteboardOperation
): WhiteboardScene {
  if (operation.kind === "board.clear") return new Map();

  const next = new Map(scene);
  for (const incoming of operation.payload.elements ?? []) {
    const current = next.get(incoming.id);
    if (!current || incomingWins(current, incoming)) {
      next.set(incoming.id, incoming);
    }
  }
  return next;
}

export function applyWhiteboardOperations(
  operations: WhiteboardOperation[]
): WhiteboardScene {
  return replayWhiteboardOperations(operations).scene;
}

export function replayWhiteboardOperations(
  operations: WhiteboardOperation[],
  currentScene: WhiteboardScene = new Map()
): WhiteboardReplay {
  let scene = new Map(currentScene);
  let cleared = new Map<string, WhiteboardElementData>();
  let latestSequence = 0;
  let includesClear = false;

  for (const operation of operations
    .slice()
    .sort((left, right) => left.sequence - right.sequence)) {
    latestSequence = Math.max(latestSequence, operation.sequence);
    if (operation.kind === "board.clear") {
      includesClear = true;
      cleared = new Map(scene);
      scene = new Map();
      continue;
    }

    scene = applyWhiteboardOperation(scene, operation);
    for (const element of operation.payload.elements ?? []) {
      // A server-accepted update after the clear starts a new generation,
      // even when Excalidraw happens to reuse the same element revision.
      cleared.delete(element.id);
    }
  }

  return {
    scene,
    latestSequence,
    clearedElements: Array.from(cleared.values()),
    includesClear
  };
}

export function elementRevision(element: WhiteboardElementData): string {
  return `${element.version}:${element.versionNonce}:${element.isDeleted === true ? 1 : 0}`;
}

export function changedElements(
  elements: readonly WhiteboardElementData[],
  revisions: Map<string, string>
): WhiteboardElementData[] {
  return elements.filter(
    (element) => revisions.get(element.id) !== elementRevision(element)
  );
}

export function noteRevisions(
  revisions: Map<string, string>,
  elements: readonly WhiteboardElementData[]
): void {
  for (const element of elements) {
    revisions.set(element.id, elementRevision(element));
  }
}

function incomingWins(
  current: WhiteboardElementData,
  incoming: WhiteboardElementData
): boolean {
  if (incoming.version !== current.version) {
    return incoming.version > current.version;
  }

  // Excalidraw resolves concurrent equal-version edits by retaining the lower
  // nonce. Matching that rule makes replay deterministic across every client.
  return incoming.versionNonce < current.versionNonce;
}
