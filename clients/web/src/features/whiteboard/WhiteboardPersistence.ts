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
import {
  clearWhiteboardOutbox,
  loadWhiteboardOutbox,
  saveWhiteboardOutbox,
  type WhiteboardOutboxEntry
} from "./whiteboardOutboxStore";

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
export type SaveStatus = "synced" | "syncing" | "unsynced" | "error";

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
  outboxKey: string;
  editor: RefCell<ExcalidrawImperativeAPI | null>;
  applyingRemote: RefCell<boolean>;
  scene: RefCell<WhiteboardScene>;
  latestSequence: RefCell<number>;
  revisions: RefCell<Map<string, string>>;
  clearedRevisions: RefCell<Map<string, string>>;
  acceptOperation: (operation: WhiteboardOperation) => void;
  onElementCount: (count: number) => void;
  onSaveStatus: (status: SaveStatus) => void;
  onPendingChange: (count: number) => void;
  onError: (message: string | null) => void;
  onReplayRequested: () => void;
}

/** The server owns history; the browser retains only unacknowledged batches. */
export class WhiteboardPersistence {
  private readonly pending = new Map<string, WhiteboardElementData>();
  private pendingBase: number | null = null;
  private outbox: WhiteboardOutboxEntry[] = [];
  private inFlight: WhiteboardOutboxEntry | null = null;
  private restorePromise: Promise<WhiteboardOutboxEntry[]> | null = null;
  private storageWrite: Promise<unknown> = Promise.resolve();
  private storageAvailable = true;
  private flushTimer: number | null = null;
  private retryTimer: number | null = null;
  private flushCompletion: Promise<void> | null = null;
  private clearRequested = false;
  private stopped = false;
  private generation = 0;
  private localChangesArmed = false;
  private postClearGuardUntil = 0;

  constructor(private readonly dependencies: WhiteboardPersistenceDependencies) {}

  async restoreOutbox(): Promise<WhiteboardOutboxEntry[]> {
    this.restorePromise ??= loadWhiteboardOutbox(this.dependencies.outboxKey).then((entries) => {
      this.outbox = entries;
      return entries;
    });
    await this.restorePromise;
    return structuredClone(this.outbox);
  }

  start(): void {
    this.stopped = false;
    this.notifyPending();
    if (this.outbox.length > 0) {
      this.dependencies.onSaveStatus("unsynced");
      this.scheduleFlush(0);
    }
  }

  discardBeforeClear(sequence: number): void {
    const discarded = this.outbox.filter((entry) => entry.baseSequence < sequence);
    this.outbox = this.outbox.filter((entry) => entry.baseSequence >= sequence);
    if (discarded.length > 0) {
      this.removeStored(discarded.map((entry) => entry.id));
      this.dependencies.onError("This board was cleared elsewhere. Earlier unsynced changes were not applied.");
    }
  }

  readonly handleEditorChange = (elements: readonly ExcalidrawElement[]) => {
    if (this.stopped || this.clearRequested || this.dependencies.applyingRemote.current ||
      !this.localChangesArmed || Date.now() < this.postClearGuardUntil) return;
    const supported = elements.filter((element) => {
      if (!allowedElementTypes.has(element.type)) return false;
      const cleared = this.dependencies.clearedRevisions.current.get(element.id);
      if (cleared === elementRevision(element as WhiteboardElementData)) return false;
      if (cleared) this.dependencies.clearedRevisions.current.delete(element.id);
      return true;
    });
    const changed = changedElements(supported as WhiteboardElementData[], this.dependencies.revisions.current);
    if (changed.length === 0) return;
    // Observe revisions before publishing status. Excalidraw emits onChange for
    // status/selection renders too, including while a request is on the wire.
    noteRevisions(this.dependencies.revisions.current, changed);
    this.pendingBase ??= this.dependencies.latestSequence.current;
    for (const element of changed) {
      const snapshot = structuredClone(element);
      this.pending.set(element.id, snapshot);
      this.dependencies.scene.current.set(element.id, snapshot);
    }
    this.notifyPending();
    this.dependencies.onElementCount(visibleElementCount(this.dependencies.scene.current));
    this.dependencies.onSaveStatus("unsynced");
    this.scheduleFlush();
  };

  readonly armLocalChanges = () => { this.localChangesArmed = true; };

  handleAuthoritativeClear(
    clearedElements: readonly WhiteboardElementData[],
    currentElements: readonly WhiteboardElementData[] = []
  ): void {
    this.generation += 1;
    this.localChangesArmed = false;
    this.postClearGuardUntil = Date.now() + 1_000;
    this.cancelTimers();
    const ids = [...this.outbox, ...(this.inFlight ? [this.inFlight] : [])].map((entry) => entry.id);
    this.pending.clear();
    this.pendingBase = null;
    this.outbox = [];
    this.inFlight = null;
    this.removeStored(ids);
    this.notifyPending();
    this.dependencies.revisions.current.clear();
    noteRevisions(this.dependencies.revisions.current, currentElements);
    this.dependencies.clearedRevisions.current.clear();
    noteRevisions(this.dependencies.clearedRevisions.current, clearedElements);
    this.dependencies.onSaveStatus("synced");
  }

  readonly clearBoard = async (): Promise<void> => {
    if (this.clearRequested) return;
    this.clearRequested = true;
    this.dependencies.onSaveStatus("syncing");
    this.cancelTimers();
    // Keep recovery data until clear is acknowledged. A failed clear must not
    // silently discard the drawing that is still visible to its author.
    this.sealPending();
    try {
      await this.flushCompletion;
      const clearedElements = Array.from(this.dependencies.scene.current.values());
      const operation = await this.dependencies.api.clearWhiteboard(
        this.dependencies.conversationId, crypto.randomUUID()
      );
      this.dependencies.acceptOperation(operation);
      this.dependencies.scene.current = new Map();
      this.dependencies.onElementCount(0);
      this.handleAuthoritativeClear(clearedElements);
      this.dependencies.editor.current?.resetScene();
      this.dependencies.onError(null);
    } catch (reason) {
      this.dependencies.onSaveStatus("error");
      this.dependencies.onError(errorText(reason));
      throw reason;
    } finally {
      this.clearRequested = false;
      if (this.outbox.length > 0) this.scheduleFlush(2_000);
    }
  };

  readonly checkpoint = (): void => {
    this.sealPending();
  };

  dispose(): void {
    this.stopped = true;
    this.cancelTimers();
    this.sealPending();
  }

  private sealPending(): void {
    if (this.pending.size === 0) return;
    const entries: WhiteboardOutboxEntry[] = [];
    let elements: WhiteboardElementData[] = [];
    let bytes = 0;
    const seal = () => {
      if (elements.length === 0) return;
      entries.push({
        id: crypto.randomUUID(),
        baseSequence: this.pendingBase ?? this.dependencies.latestSequence.current,
        elements,
        createdAt: new Date().toISOString()
      });
      elements = [];
      bytes = 0;
    };
    for (const element of this.pending.values()) {
      const size = new TextEncoder().encode(JSON.stringify(element)).length;
      if (elements.length >= 50 || bytes + size > 480_000) seal();
      elements.push(element);
      bytes += size;
    }
    seal();
    this.pending.clear();
    this.pendingBase = null;
    this.outbox.push(...entries);
    // IDs and payloads become immutable together, before their first request.
    // Retrying an uncertain acknowledgement always uses the exact same bytes.
    const write = saveWhiteboardOutbox(this.dependencies.outboxKey, entries).then((saved) => {
      this.storageAvailable = saved;
    });
    this.storageWrite = Promise.all([this.storageWrite, write]);
    this.notifyPending();
  }

  private removeStored(ids: string[]): void {
    if (ids.length === 0) return;
    this.storageWrite = this.storageWrite.then(() =>
      clearWhiteboardOutbox(this.dependencies.outboxKey, ids)
    );
  }

  private notifyPending(): void {
    if (this.stopped) return;
    this.dependencies.onPendingChange(
      this.outbox.length + (this.inFlight ? 1 : 0) + (this.pending.size > 0 ? 1 : 0)
    );
  }

  private scheduleFlush(delay = 350): void {
    if (this.stopped) return;
    if (this.flushTimer !== null) window.clearTimeout(this.flushTimer);
    this.flushTimer = window.setTimeout(() => {
      this.flushTimer = null;
      this.sealPending();
      if (this.retryTimer === null) void this.flushPending();
    }, delay);
  }

  private async flushPending(): Promise<void> {
    if (this.stopped || this.clearRequested || this.flushCompletion || this.outbox.length === 0) return;
    const batch = this.outbox.shift()!;
    const generation = this.generation;
    this.inFlight = batch;
    this.notifyPending();
    this.dependencies.onSaveStatus("syncing");
    this.flushCompletion = this.sendBatch(batch, generation);
    await this.flushCompletion;
    this.flushCompletion = null;
    if (this.stopped) return;
    this.notifyPending();
    if (!this.clearRequested && this.outbox.length > 0 && this.retryTimer === null) {
      this.scheduleFlush(0);
    }
  }

  private async sendBatch(batch: WhiteboardOutboxEntry, generation: number): Promise<void> {
    try {
      await this.storageWrite;
      if (generation !== this.generation || this.stopped) return;
      const operation = await this.dependencies.api.appendWhiteboardSceneUpdate(
        this.dependencies.conversationId, batch.id, batch.baseSequence, batch.elements
      );
      this.removeStored([batch.id]);
      if (generation !== this.generation || this.stopped) return;
      this.dependencies.acceptOperation(operation);
      noteRevisions(this.dependencies.revisions.current, operation.payload.elements ?? batch.elements);
      // An acknowledgement of an older revision must not make the newer local
      // revision appear unsent a second time.
      for (const entry of this.outbox) noteRevisions(this.dependencies.revisions.current, entry.elements);
      noteRevisions(this.dependencies.revisions.current, [...this.pending.values()]);
      this.dependencies.onError(null);
      this.dependencies.onSaveStatus(this.outbox.length > 0 || this.pending.size > 0 ? "unsynced" : "synced");
    } catch (reason) {
      if (generation !== this.generation) return;
      if (isApiErrorCode(reason, "stale_whiteboard_generation")) {
        const ids = [batch, ...this.outbox].map((entry) => entry.id);
        this.pending.clear();
        this.pendingBase = null;
        this.outbox = [];
        this.removeStored(ids);
        if (!this.stopped) {
          this.dependencies.onSaveStatus("error");
          this.dependencies.onError("This board was cleared elsewhere. Local unsynced changes were not applied.");
          this.dependencies.onReplayRequested();
        }
      } else {
        this.outbox.unshift(batch);
        if (!this.stopped) {
          this.dependencies.onSaveStatus("error");
          this.dependencies.onError(errorText(reason) + (this.storageAvailable
            ? " Changes are retained on this device and will retry."
            : " Browser recovery storage is unavailable. Keep this tab open while changes retry."));
          this.retryTimer = window.setTimeout(() => {
            this.retryTimer = null;
            void this.flushPending();
          }, 2_000);
        }
      }
    } finally {
      this.inFlight = null;
    }
  }

  private cancelTimers(): void {
    if (this.flushTimer !== null) window.clearTimeout(this.flushTimer);
    if (this.retryTimer !== null) window.clearTimeout(this.retryTimer);
    this.flushTimer = null;
    this.retryTimer = null;
  }
}

function visibleElementCount(scene: WhiteboardScene): number {
  return Array.from(scene.values()).filter((element) => element.isDeleted !== true).length;
}

function isApiErrorCode(reason: unknown, code: string): boolean {
  return (
    (reason instanceof ApiError && reason.code === code) ||
    (typeof reason === "object" && reason !== null && "code" in reason && reason.code === code)
  );
}
