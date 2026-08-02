import { reconcileElements, restoreElements } from "@excalidraw/excalidraw";
import type {
  AppState,
  Collaborator,
  ExcalidrawImperativeAPI
} from "@excalidraw/excalidraw/types";
import type { ExcalidrawElement } from "@excalidraw/excalidraw/element/types";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useSession } from "../../app/session";
import { useOptionalWorkspaceData } from "../../app/workspace-data";
import { errorText } from "../../lib/format";
import { socketEndpoint } from "../../realtime";
import type {
  ConnectionStatus,
  WhiteboardElementData,
  WhiteboardOperation,
  WhiteboardOperationPage,
  WhiteboardPresenceEvent
} from "../../types";
import {
  applyWhiteboardOperation,
  noteRevisions,
  replayWhiteboardOperations,
  type WhiteboardScene
} from "./sceneModel";
import {
  WhiteboardRealtime,
  type WhiteboardRealtimeCallbacks
} from "./WhiteboardRealtime";
import { orderWhiteboardOperations } from "./operationStream";
import { WhiteboardPersistence } from "./WhiteboardPersistence";

type PointerUpdate = {
  pointer: { x: number; y: number; tool: "pointer" | "laser" };
  button: "up" | "down";
};

export interface WhiteboardCollaborationApi {
  socketTicket(): Promise<{ ticket: string; expires_in: number }>;
  whiteboardOperations(
    conversationId: string,
    afterSequence?: number,
    limit?: number
  ): Promise<WhiteboardOperationPage>;
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

export interface WhiteboardCollaborationOptions {
  api: WhiteboardCollaborationApi;
  userId: string;
  deviceId: string;
  users: ReadonlyArray<{ id: string; display_name: string }>;
}

export function useWhiteboardCollaboration(
  conversationId: string,
  options?: WhiteboardCollaborationOptions,
  focusElementIds: readonly string[] = []
) {
  const sessionContext = useSession();
  const workspaceData = useOptionalWorkspaceData();
  const api = options?.api ?? sessionContext.api;
  const sessionUserId = options?.userId ?? sessionContext.session?.user.id;
  const sessionDeviceId = options?.deviceId ?? sessionContext.session?.device.id;
  const users = options?.users ?? workspaceData?.users ?? [];
  const editorRef = useRef<ExcalidrawImperativeAPI | null>(null);
  const editorAttachFrameRef = useRef<number | null>(null);
  const remoteApplyFrameRef = useRef<number | null>(null);
  const applyingRemoteRef = useRef(false);
  const sceneRef = useRef<WhiteboardScene>(new Map());
  const latestSequenceRef = useRef(0);
  const operationQueueRef = useRef(new Map<number, WhiteboardOperation>());
  const revisionsRef = useRef(new Map<string, string>());
  const clearedRevisionsRef = useRef(new Map<string, string>());
  const realtimeRef = useRef<WhiteboardRealtime | null>(null);
  const bufferedOperationsRef = useRef<WhiteboardOperation[]>([]);
  const applyRemoteOperationRef = useRef<(operation: WhiteboardOperation) => void>(
    () => undefined
  );
  const editorReadyRef = useRef(false);
  const collaboratorsRef = useRef(new Map<string, Collaborator>());
  const collaboratorExpiryRef = useRef(new Map<string, number>());
  const usersByIdRef = useRef(new Map<string, string>());
  const [initialElements, setInitialElements] = useState<
    readonly ExcalidrawElement[] | null
  >(null);
  const [connectionStatus, setConnectionStatus] =
    useState<ConnectionStatus>("connecting");
  const [saveStatus, setSaveStatus] = useState<"saved" | "saving" | "error">(
    "saved"
  );
  const [error, setError] = useState<string | null>(null);
  const [historyError, setHistoryError] = useState<string | null>(null);
  const [historyAttempt, setHistoryAttempt] = useState(0);
  const [collaboratorCount, setCollaboratorCount] = useState(0);
  const [elementCount, setElementCount] = useState(0);
  const [selectedElementIds, setSelectedElementIds] = useState<string[]>([]);
  const persistence = useMemo(
    () =>
      new WhiteboardPersistence({
        api,
        conversationId,
        editor: editorRef,
        applyingRemote: applyingRemoteRef,
        scene: sceneRef,
        latestSequence: latestSequenceRef,
        revisions: revisionsRef,
        clearedRevisions: clearedRevisionsRef,
        acceptOperation: (operation) =>
          applyRemoteOperationRef.current(operation),
        onElementCount: setElementCount,
        onSaveStatus: setSaveStatus,
        onError: setError,
        onReplayRequested: () =>
          setHistoryAttempt((attempt) => attempt + 1)
      }),
    [api, conversationId]
  );
  const usersById = useMemo(
    () => new Map(users.map((user) => [user.id, user.display_name])),
    [users]
  );
  usersByIdRef.current = usersById;

  const focusElementKey = focusElementIds.join("\0");
  useEffect(() => {
    if (!sessionUserId || !sessionDeviceId) return;
    let current = true;
    let reconnectTimer: number | null = null;
    let reconnectAttempt = 0;
    let initialReplayPromise: Promise<void> | null = null;
    let catchUpPromise: Promise<void> | null = null;

    const callbacks: WhiteboardRealtimeCallbacks = {
      onOperation(operation) {
        if (!current) return;
        if (!editorReadyRef.current || !editorRef.current) {
          bufferedOperationsRef.current.push(operation);
          return;
        }
        acceptOperations([operation]);
      },
      onPresence(presence) {
        if (
          !current ||
          (presence.user_id === sessionUserId &&
            presence.device_id === sessionDeviceId)
        ) return;
        applyPresence(presence);
      },
      onStatus(status) {
        if (!current) return;
        setConnectionStatus(
          status === "live" ? "live" : status === "offline" ? "offline" : "connecting"
        );
        if (status === "offline" && reconnectTimer === null) {
          const delay = [1_000, 2_000, 5_000, 10_000][reconnectAttempt] ?? 15_000;
          reconnectAttempt += 1;
          reconnectTimer = window.setTimeout(() => {
            reconnectTimer = null;
            void connect();
          }, delay);
        }
      },
      onError(message) {
        if (current) setError(message);
      }
    };

    async function connect() {
      realtimeRef.current?.disconnect(false);
      realtimeRef.current = null;
      try {
        const { ticket } = await api.socketTicket();
        if (!current) return;
        const realtime = new WhiteboardRealtime(
          socketEndpoint(import.meta.env.VITE_API_BASE_URL || ""),
          ticket,
          conversationId,
          callbacks
        );
        realtimeRef.current = realtime;
        await realtime.connect();
        reconnectAttempt = 0;
        setError(null);
        await initialReplayPromise?.then(
          () => catchUpDurableScene(),
          () => undefined
        );
      } catch (reason) {
        if (!current) return;
        callbacks.onError(errorText(reason));
        callbacks.onStatus("offline");
      }
    }

    async function loadDurableScene() {
      const operations: WhiteboardOperation[] = [];
      let afterSequence = 0;
      let hasMore = true;

      while (current && hasMore) {
        const page = await api.whiteboardOperations(conversationId, afterSequence);
        operations.push(...page.data);
        afterSequence = page.page.next_after_sequence;
        hasMore = page.page.has_more;
      }
      if (!current) return;

      const all = uniqueOperations([
        ...operations,
        ...bufferedOperationsRef.current
      ]);
      bufferedOperationsRef.current = [];
      const replay = replayWhiteboardOperations(
        all,
        sceneRef.current
      );
      sceneRef.current = replay.scene;
      latestSequenceRef.current = replay.latestSequence;
      operationQueueRef.current.clear();
      const elements = Array.from(replay.scene.values());
      if (replay.includesClear) {
        persistence.handleAuthoritativeClear(replay.clearedElements, elements);
      } else {
        revisionsRef.current.clear();
        noteRevisions(revisionsRef.current, elements);
        clearedRevisionsRef.current.clear();
      }
      setElementCount(visibleElementCount(sceneRef.current));
      const restored = restoreElements(
        elements as never,
        editorRef.current?.getSceneElementsIncludingDeleted() ?? null
      );
      if (editorRef.current) {
        updateEditorFromRemote({ elements: restored });
      } else {
        setInitialElements(restored);
      }
      setHistoryError(null);
    }

    function catchUpDurableScene(): Promise<void> {
      if (catchUpPromise) return catchUpPromise;

      catchUpPromise = (async () => {
        let afterSequence = latestSequenceRef.current;
        let hasMore = true;

        while (current && hasMore) {
          const page = await api.whiteboardOperations(
            conversationId,
            afterSequence
          );
          if (!current) return;
          if (!editorReadyRef.current || !editorRef.current) {
            bufferedOperationsRef.current.push(...page.data);
          } else {
            acceptOperations(page.data);
          }
          afterSequence = page.page.next_after_sequence;
          hasMore = page.page.has_more;
        }
      })().finally(() => {
        catchUpPromise = null;
      });

      return catchUpPromise;
    }

    function acceptOperations(operations: WhiteboardOperation[]) {
      const ordered = orderWhiteboardOperations(
        latestSequenceRef.current,
        operationQueueRef.current,
        operations
      );
      latestSequenceRef.current = ordered.latestSequence;
      for (const operation of ordered.ready) applyRemoteOperation(operation);
      if (ordered.hasGap) void catchUpDurableScene();
    }

    function applyRemoteOperation(operation: WhiteboardOperation) {
      const previousElements = Array.from(sceneRef.current.values());
      const next = applyWhiteboardOperation(sceneRef.current, operation);
      sceneRef.current = next;
      setElementCount(visibleElementCount(next));
      if (operation.kind === "scene.update") {
        noteRevisions(revisionsRef.current, operation.payload.elements ?? []);
        for (const element of operation.payload.elements ?? []) {
          clearedRevisionsRef.current.delete(element.id);
        }
      } else {
        persistence.handleAuthoritativeClear(previousElements);
      }

      const editor = editorRef.current;
      if (!editor) return;
      if (operation.kind === "board.clear") {
        resetEditorFromRemote();
        return;
      }
      const restored = restoreElements(
        Array.from(next.values()) as never,
        editor.getSceneElementsIncludingDeleted()
      );
      const reconciled = reconcileElements(
        editor.getSceneElementsIncludingDeleted(),
        restored as never,
        editor.getAppState()
      );
      updateEditorFromRemote({ elements: reconciled });
    }
    applyRemoteOperationRef.current = (operation) => acceptOperations([operation]);

    function applyPresence(presence: WhiteboardPresenceEvent) {
      const collaboratorId = `${presence.user_id}:${presence.device_id}`;
      const collaborator: Collaborator = {
        id: collaboratorId,
        username: usersByIdRef.current.get(presence.user_id) || "Collaborator",
        pointer: { ...presence.pointer, renderCursor: true },
        button: presence.button ? "down" : "up",
        selectedElementIds: Object.fromEntries(
          presence.selected_element_ids.map((id) => [id, true])
        ),
        color: collaboratorColor(collaboratorId)
      };
      collaboratorsRef.current.set(collaboratorId, collaborator);
      collaboratorExpiryRef.current.set(collaboratorId, Date.now() + 15_000);
      publishCollaborators();
    }

    function publishCollaborators() {
      const now = Date.now();
      for (const [collaboratorId, expiresAt] of collaboratorExpiryRef.current) {
        if (expiresAt <= now) {
          collaboratorExpiryRef.current.delete(collaboratorId);
          collaboratorsRef.current.delete(collaboratorId);
        }
      }
      setCollaboratorCount(collaboratorsRef.current.size);
      editorRef.current?.updateScene({
        collaborators: collaboratorsRef.current as never
      });
    }

    function updateEditorFromRemote(scene: Parameters<ExcalidrawImperativeAPI["updateScene"]>[0]) {
      const editor = editorRef.current;
      if (!editor) return;
      applyingRemoteRef.current = true;
      cancelRemoteApplyFrame();
      editor.updateScene(scene);
      finishRemoteApplyOnNextFrame();
    }

    function resetEditorFromRemote() {
      const editor = editorRef.current;
      if (!editor) return;
      applyingRemoteRef.current = true;
      cancelRemoteApplyFrame();
      // A clear is a generation boundary, so the local undo history must not
      // retain objects that another participant authoritatively erased.
      editor.resetScene();
      finishRemoteApplyOnNextFrame();
    }

    function cancelRemoteApplyFrame() {
      if (remoteApplyFrameRef.current !== null) {
        window.cancelAnimationFrame(remoteApplyFrameRef.current);
      }
    }

    function finishRemoteApplyOnNextFrame() {
      remoteApplyFrameRef.current = window.requestAnimationFrame(() => {
        remoteApplyFrameRef.current = null;
        applyingRemoteRef.current = false;
      });
    }

    const expiryTimer = window.setInterval(publishCollaborators, 5_000);
    // Durable replay is an independent availability boundary. A slow or
    // unavailable WebSocket must never prevent an authorized member from
    // opening the last persisted scene.
    initialReplayPromise = loadDurableScene();
    void initialReplayPromise.catch((reason) => {
      if (current) setHistoryError(errorText(reason));
    });
    if (import.meta.env.VITE_DISABLE_REALTIME === "true") {
      setConnectionStatus("offline");
    } else {
      void connect();
    }

    return () => {
      current = false;
      realtimeRef.current?.disconnect(false);
      realtimeRef.current = null;
      if (reconnectTimer !== null) window.clearTimeout(reconnectTimer);
      window.clearInterval(expiryTimer);
      if (remoteApplyFrameRef.current !== null) {
        window.cancelAnimationFrame(remoteApplyFrameRef.current);
        remoteApplyFrameRef.current = null;
      }
      applyingRemoteRef.current = false;
    };
  }, [
    api,
    conversationId,
    historyAttempt,
    persistence,
    sessionDeviceId,
    sessionUserId
  ]);

  useEffect(
    () => () => {
      persistence.dispose();
      if (editorAttachFrameRef.current !== null) {
        window.cancelAnimationFrame(editorAttachFrameRef.current);
      }
      if (remoteApplyFrameRef.current !== null) {
        window.cancelAnimationFrame(remoteApplyFrameRef.current);
      }
    },
    [persistence]
  );

  function attachEditor(editor: ExcalidrawImperativeAPI) {
    editorRef.current = editor;
    editorReadyRef.current = false;
    if (editorAttachFrameRef.current !== null) {
      window.cancelAnimationFrame(editorAttachFrameRef.current);
    }
    // Excalidraw supplies its imperative API while its class component is
    // still being constructed. Defer every stateful API call until the first
    // committed frame so React never receives a pre-mount setState.
    editorAttachFrameRef.current = window.requestAnimationFrame(() => {
      editorAttachFrameRef.current = null;
      if (editorRef.current !== editor) return;
      editorReadyRef.current = true;
      editor.updateScene({ collaborators: collaboratorsRef.current as never });
      const buffered = bufferedOperationsRef.current
        .splice(0)
        .sort((left, right) => left.sequence - right.sequence);
      for (const operation of buffered) applyRemoteOperationRef.current(operation);
    });
  }

  function sendPointerUpdate(payload: PointerUpdate) {
    const selectedElementIds = Object.keys(
      editorRef.current?.getAppState().selectedElementIds ?? {}
    );
    realtimeRef.current?.sendPresence({
      pointer: payload.pointer,
      button: payload.button,
      selected_element_ids: selectedElementIds
    });
  }

  const handleEditorChange = useCallback((
    elements: readonly ExcalidrawElement[],
    appState?: Pick<AppState, "selectedElementIds">
  ) => {
    const nextSelectedElementIds = Object.keys(appState?.selectedElementIds ?? {});
    setSelectedElementIds((current) =>
      current.length === nextSelectedElementIds.length &&
      current.every((id, index) => id === nextSelectedElementIds[index])
        ? current
        : nextSelectedElementIds
    );
    persistence.handleEditorChange(elements);
  }, [persistence]);

  const messageReference = () => {
    const elementIds = Object.keys(
      editorRef.current?.getAppState().selectedElementIds ?? {}
    ).slice(0, 20);
    if (elementIds.length === 0) return null;
    return {
      element_ids: elementIds,
      board_sequence: latestSequenceRef.current,
      label: elementIds.length === 1 ? "Whiteboard object" : `${elementIds.length} whiteboard objects`
    };
  };

  useEffect(() => {
    if (!editorReadyRef.current || !editorRef.current || focusElementIds.length === 0) return;
    const selection = Object.fromEntries(focusElementIds.map((id) => [id, true as const]));
    editorRef.current.updateScene({ appState: { selectedElementIds: selection } });
    const selected = editorRef.current
      .getSceneElements()
      .filter((element) => selection[element.id]);
    if (selected.length > 0) editorRef.current.scrollToContent(selected, { fitToContent: true });
  }, [focusElementKey, initialElements]);

  return {
    initialElements,
    connectionStatus,
    saveStatus,
    error,
    historyError,
    collaboratorCount,
    elementCount,
    attachEditor,
    handleEditorChange,
    selectedElementIds,
    messageReference,
    sendPointerUpdate,
    armLocalChanges: persistence.armLocalChanges,
    retryHistory: () => {
      setHistoryError(null);
      setHistoryAttempt((attempt) => attempt + 1);
    },
    clearBoard: persistence.clearBoard
  };
}

function uniqueOperations(operations: WhiteboardOperation[]): WhiteboardOperation[] {
  return Array.from(
    new Map(operations.map((operation) => [operation.id, operation])).values()
  );
}

function collaboratorColor(userId: string): Collaborator["color"] {
  const colors = [
    { background: "#dff7f3", stroke: "#087f71" },
    { background: "#e5efff", stroke: "#2458a6" },
    { background: "#f5e9ff", stroke: "#7540a8" },
    { background: "#fff1d6", stroke: "#9b6100" },
    { background: "#ffe5e7", stroke: "#a6323b" }
  ];
  let hash = 0;
  for (const character of userId) hash = (hash * 31 + character.charCodeAt(0)) | 0;
  return colors[Math.abs(hash) % colors.length];
}

function visibleElementCount(scene: WhiteboardScene): number {
  return Array.from(scene.values()).filter((element) => element.isDeleted !== true)
    .length;
}
