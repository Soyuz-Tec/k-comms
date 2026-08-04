import type { ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types";
import type { ExcalidrawElement } from "@excalidraw/excalidraw/element/types";
import { ApiError } from "../../api";
import { errorText } from "../../lib/format";
import type {
  WhiteboardElementData,
  WhiteboardOperation
} from "../../types";
import {
  changedElements,
  elementRevision,
  noteRevisions,
  type WhiteboardScene
} from "./sceneModel";

const allowedElementTypes = new Set([
  "rectangle",
  "diamond",
  "ellipse",
  "line",
  "arrow",
  "freedraw",
  "text",
  "frame"
]);

type RefCell<T> = { current: T };
type SaveStatus = "saved" | "saving" | "error";

interface PersistenceApi {
  appendWhiteboardSceneUpdate(
    conversationId: string,
    clientOperationId: string,
    baseSequence: number,
    elements: WhiteboardElementData[]
  ): Promise<WhiteboardOperation>;
  clearWhiteboard(
    conversationId: string,
    clientOperationId: string
  ): Promise<WhiteboardOperation>;
}

export interface WhiteboardPersistenceDependencies {
  api: PersistenceApi;
  conversationId: string;
  editor: RefCell<ExcalidrawImperativeAPI | null>;
  applyingRemote: RefCell<boolean>;
  scene: RefCell<WhiteboardScene>;
  latestSequence: RefCell<number>;
  revisions: RefCell<Map<string, string>>;
  clearedRevisions: RefCell<Map<string, string>>;
  acceptOperation: (operation: WhiteboardOperation) => void;
  onElementCount: (count: number) => void;
  onSaveStatus: (status: SaveStatus) => void;
  onError: (message: string | null) => void;
  onReplayRequested: () => void;
}

export class WhiteboardPersistence {
  private readonly pending = new Map<string, WhiteboardElementData>();
  private flushTimer: number | null = null;
  private retryTimer: number | null = null;
  private flushInFlight = false;
  private flushCompletion: Promise<void> | null = null;
  private clearRequested = false;
  // Excalidraw emits onChange while restoring a durable scene. Persist only
  // after an actual pointer or keyboard interaction arms local editing.
  private localChangesArmed = false;
  private postClearGuardUntil = 0;

  constructor(private readonly dependencies: WhiteboardPersistenceDependencies) {}

  readonly handleEditorChange = (elements: readonly ExcalidrawElement[]) => {
    if (
      this.clearRequested ||
      this.dependencies.applyingRemote.current ||
      !this.localChangesArmed ||
      Date.now() < this.postClearGuardUntil
    ) return;

    const supported = elements.filter((element) => {
      if (!allowedElementTypes.has(element.type)) return false;
      const clearedRevision = this.dependencies.clearedRevisions.current.get(
        element.id
      );
      if (
        clearedRevision ===
        elementRevision(element as WhiteboardElementData)
      ) return false;
      if (clearedRevision) {
        this.dependencies.clearedRevisions.current.delete(element.id);
      }
      return true;
    });
    const changed = changedElements(
      supported as unknown as WhiteboardElementData[],
      this.dependencies.revisions.current
    );
    if (changed.length === 0) return;

    for (const element of changed) {
      this.pending.set(element.id, element);
      this.dependencies.scene.current.set(element.id, element);
    }
    this.dependencies.onElementCount(
      visibleElementCount(this.dependencies.scene.current)
    );
    this.scheduleFlush();
  };

  readonly armLocalChanges = () => {
    this.localChangesArmed = true;
  };

  handleAuthoritativeClear(
    clearedElements: readonly WhiteboardElementData[],
    currentElements: readonly WhiteboardElementData[] = []
  ): void {
    this.localChangesArmed = false;
    this.postClearGuardUntil = Date.now() + 1_000;
    this.cancelTimers();
    this.dependencies.revisions.current.clear();
    noteRevisions(this.dependencies.revisions.current, currentElements);
    this.dependencies.clearedRevisions.current.clear();
    noteRevisions(this.dependencies.clearedRevisions.current, clearedElements);
    this.pending.clear();
  }

  readonly clearBoard = async (): Promise<void> => {
    if (this.clearRequested) return;
    const clearedElements = Array.from(this.dependencies.scene.current.values());
    this.clearRequested = true;
    this.dependencies.onSaveStatus("saving");
    this.cancelTimers();
    this.pending.clear();

    try {
      await this.flushCompletion;
      const operation = await this.dependencies.api.clearWhiteboard(
        this.dependencies.conversationId,
        crypto.randomUUID()
      );
      this.dependencies.acceptOperation(operation);
      this.dependencies.scene.current = new Map();
      this.dependencies.onElementCount(0);
      this.handleAuthoritativeClear(clearedElements);
      this.dependencies.editor.current?.resetScene();
      this.dependencies.onSaveStatus("saved");
      this.dependencies.onError(null);
    } catch (reason) {
      this.dependencies.onSaveStatus("error");
      this.dependencies.onError(errorText(reason));
      throw reason;
    } finally {
      this.clearRequested = false;
    }
  };

  dispose(): void {
    this.cancelTimers();
  }

  private scheduleFlush(delay = 350): void {
    this.dependencies.onSaveStatus("saving");
    if (this.flushTimer !== null) window.clearTimeout(this.flushTimer);
    this.flushTimer = window.setTimeout(() => {
      this.flushTimer = null;
      void this.flushPending();
    }, delay);
  }

  private async flushPending(): Promise<void> {
    if (this.flushInFlight || this.pending.size === 0) return;
    this.flushInFlight = true;
    const batch = Array.from(this.pending.values()).slice(0, 50);
    for (const element of batch) this.pending.delete(element.id);

    const persistence = this.dependencies.api.appendWhiteboardSceneUpdate(
      this.dependencies.conversationId,
      crypto.randomUUID(),
      this.dependencies.latestSequence.current,
      batch
    );
    this.flushCompletion = persistence.then(() => undefined, () => undefined);

    try {
      const operation = await persistence;
      this.dependencies.acceptOperation(operation);
      noteRevisions(
        this.dependencies.revisions.current,
        operation.payload.elements ?? batch
      );
      this.dependencies.onSaveStatus("saved");
      this.dependencies.onError(null);
    } catch (reason) {
      if (isApiErrorCode(reason, "stale_whiteboard_generation")) {
        this.pending.clear();
        this.dependencies.onSaveStatus("saved");
        this.dependencies.onReplayRequested();
      } else if (!this.clearRequested) {
        for (const element of batch) {
          const queued = this.pending.get(element.id);
          if (!queued || queued.version <= element.version) {
            this.pending.set(element.id, element);
          }
        }
        this.dependencies.onSaveStatus("error");
        this.dependencies.onError(
          `${errorText(reason)} Changes are retained in this tab and will retry.`
        );
        this.retryTimer = window.setTimeout(() => {
          this.retryTimer = null;
          void this.flushPending();
        }, 2_000);
      }
    } finally {
      this.flushInFlight = false;
      this.flushCompletion = null;
      if (
        !this.clearRequested &&
        this.pending.size > 0 &&
        this.retryTimer === null
      ) this.scheduleFlush(0);
    }
  }

  private cancelTimers(): void {
    if (this.flushTimer !== null) {
      window.clearTimeout(this.flushTimer);
      this.flushTimer = null;
    }
    if (this.retryTimer !== null) {
      window.clearTimeout(this.retryTimer);
      this.retryTimer = null;
    }
  }
}

function visibleElementCount(scene: WhiteboardScene): number {
  return Array.from(scene.values()).filter((element) => element.isDeleted !== true)
    .length;
}

function isApiErrorCode(reason: unknown, code: string): boolean {
  return (
    (reason instanceof ApiError && reason.code === code) ||
    (typeof reason === "object" &&
      reason !== null &&
      "code" in reason &&
      reason.code === code)
  );
}
