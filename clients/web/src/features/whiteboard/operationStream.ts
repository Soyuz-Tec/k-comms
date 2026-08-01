import type { WhiteboardOperation } from "../../types";

export type WhiteboardOperationStreamResult = {
  ready: WhiteboardOperation[];
  latestSequence: number;
  hasGap: boolean;
};

export function orderWhiteboardOperations(
  latestSequence: number,
  queued: Map<number, WhiteboardOperation>,
  incoming: Iterable<WhiteboardOperation>
): WhiteboardOperationStreamResult {
  for (const operation of incoming) {
    if (operation.sequence > latestSequence && !queued.has(operation.sequence)) {
      queued.set(operation.sequence, operation);
    }
  }

  const ready: WhiteboardOperation[] = [];
  let nextSequence = latestSequence;

  while (queued.size > 0) {
    const next = queued.get(nextSequence + 1);
    if (next) {
      queued.delete(next.sequence);
      ready.push(next);
      nextSequence = next.sequence;
      continue;
    }

    const authoritativeClear = Array.from(queued.values())
      .filter((operation) => operation.kind === "board.clear")
      .sort((left, right) => left.sequence - right.sequence)[0];
    if (!authoritativeClear) break;

    // A clear makes every earlier operation irrelevant to the visible scene,
    // so compact history may safely begin at that sequence.
    for (const sequence of queued.keys()) {
      if (sequence <= authoritativeClear.sequence) queued.delete(sequence);
    }
    ready.push(authoritativeClear);
    nextSequence = authoritativeClear.sequence;
  }

  return {
    ready,
    latestSequence: nextSequence,
    hasGap: queued.size > 0
  };
}
