import { act, renderHook, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "../../api";
import type { WhiteboardOperation } from "../../types";
import type { WhiteboardPresenceEvent } from "../../types";
import { useWhiteboardCollaboration } from "./useWhiteboardCollaboration";

const mocks = vi.hoisted(() => {
  const socketTicket = vi.fn();
  const whiteboardOperations = vi.fn();
  const appendWhiteboardSceneUpdate = vi.fn();
  const clearWhiteboard = vi.fn();
  const connect = vi.fn();

  return {
    socketTicket,
    whiteboardOperations,
    appendWhiteboardSceneUpdate,
    clearWhiteboard,
    connect,
    api: {
      socketTicket,
      whiteboardOperations,
      appendWhiteboardSceneUpdate,
      clearWhiteboard
    },
    sendPresence: vi.fn(),
    disconnect: vi.fn(),
    callbacks: null as null | {
      onOperation: (operation: WhiteboardOperation) => void;
      onPresence: (presence: WhiteboardPresenceEvent) => void;
      onStatus: (status: "connecting" | "live" | "offline") => void;
    }
  };
});

vi.mock("@excalidraw/excalidraw", () => ({
  restoreElements: (elements: unknown) => elements,
  reconcileElements: (_current: unknown, incoming: unknown) => incoming
}));

vi.mock("../../app/session", () => ({
  useSession: () => ({
    api: mocks.api,
    session: { user: { id: "user-one" }, device: { id: "device-one" } }
  })
}));

vi.mock("../../app/workspace-data", () => ({
  useWorkspaceData: () => ({
    users: [{ id: "user-two", display_name: "Second collaborator" }]
  })
}));

vi.mock("./WhiteboardRealtime", () => ({
  WhiteboardRealtime: class {
    constructor(
      _endpoint: string,
      _ticket: string,
      _conversationId: string,
      callbacks: NonNullable<typeof mocks.callbacks>
    ) {
      mocks.callbacks = callbacks;
    }

    connect() {
      mocks.callbacks?.onStatus("connecting");
      return mocks.connect().then(() => mocks.callbacks?.onStatus("live"));
    }

    sendPresence(input: unknown) {
      mocks.sendPresence(input);
    }

    disconnect(notify: boolean) {
      mocks.disconnect(notify);
    }
  }
}));

describe("useWhiteboardCollaboration", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.callbacks = null;
    mocks.socketTicket.mockResolvedValue({ ticket: "socket-ticket" });
    mocks.whiteboardOperations.mockResolvedValue({
      data: [],
      page: { has_more: false, next_after_sequence: 0 }
    });
    mocks.appendWhiteboardSceneUpdate.mockImplementation(
      (
        _conversationId: string,
        clientOperationId: string,
        baseSequence: number,
        elements: unknown[]
      ) =>
        Promise.resolve(
          operation(
            clientOperationId,
            elements,
            "scene.update",
            "user-one",
            baseSequence + 1
          )
        )
    );
    mocks.clearWhiteboard.mockResolvedValue(
      operation("clear-operation", [], "board.clear", "user-one", 4)
    );
    mocks.connect.mockResolvedValue(undefined);
  });

  afterEach(() => vi.useRealTimers());

  it("replays, applies same-user multi-device events, saves local edits, and clears", async () => {
    const { result, unmount } = renderHook(() =>
      useWhiteboardCollaboration("conversation-one")
    );

    await waitFor(() => expect(result.current.initialElements).toEqual([]));
    expect(result.current.connectionStatus).toBe("live");

    const updateScene = vi.fn();
    const resetScene = vi.fn();
    const editor = {
      updateScene,
      resetScene,
      getSceneElementsIncludingDeleted: vi.fn(() => []),
      getAppState: vi.fn(() => ({ selectedElementIds: {} }))
    };

    await act(async () => {
      result.current.attachEditor(editor as never);
      await new Promise<void>((resolve) =>
        window.requestAnimationFrame(() => resolve())
      );
    });

    act(() =>
      mocks.callbacks?.onPresence({
        user_id: "user-one",
        device_id: "device-two",
        pointer: { x: 10, y: 20, tool: "pointer" },
        button: false,
        selected_element_ids: []
      })
    );
    expect(result.current.collaboratorCount).toBe(1);

    const remoteElement = element("remote-element", 1, 4);
    act(() =>
      mocks.callbacks?.onOperation(
        operation("remote-operation", [remoteElement], "scene.update", "user-one")
      )
    );
    expect(updateScene).toHaveBeenCalledWith({ elements: [remoteElement] });
    expect(result.current.elementCount).toBe(1);

    act(() =>
      mocks.callbacks?.onOperation(
        operation("remote-clear", [], "board.clear", "user-two", 2)
      )
    );
    expect(resetScene).toHaveBeenCalledTimes(1);
    expect(result.current.elementCount).toBe(0);
    await act(async () => {
      await new Promise<void>((resolve) =>
        window.requestAnimationFrame(() => resolve())
      );
    });

    vi.useFakeTimers();
    act(() => result.current.handleEditorChange([remoteElement] as never));
    await act(async () => vi.advanceTimersByTimeAsync(350));
    expect(mocks.appendWhiteboardSceneUpdate).not.toHaveBeenCalled();

    act(() => result.current.armLocalChanges());
    await act(async () => vi.advanceTimersByTimeAsync(1_000));
    const localElement = element("local-element", 1, 8);
    act(() => result.current.handleEditorChange([localElement] as never));
    expect(result.current.saveStatus).toBe("saving");

    await act(async () => vi.advanceTimersByTimeAsync(350));
    expect(mocks.appendWhiteboardSceneUpdate).toHaveBeenCalledWith(
      "conversation-one",
      expect.any(String),
      2,
      [localElement]
    );
    expect(result.current.saveStatus).toBe("saved");

    await act(async () => result.current.clearBoard());
    expect(mocks.clearWhiteboard).toHaveBeenCalledWith(
      "conversation-one",
      expect.any(String)
    );
    expect(resetScene).toHaveBeenCalled();
    expect(result.current.elementCount).toBe(0);

    unmount();
    expect(mocks.disconnect).toHaveBeenCalledWith(false);
  });

  it("serializes an in-flight save before clearing so stale elements cannot reappear", async () => {
    let resolveSave: (() => void) | undefined;
    mocks.appendWhiteboardSceneUpdate.mockImplementation(
      (
        _conversationId: string,
        clientOperationId: string,
        _baseSequence: number,
        elements: unknown[]
      ) =>
        new Promise<WhiteboardOperation>((resolve) => {
          resolveSave = () => resolve(operation(clientOperationId, elements));
        })
    );

    const { result } = renderHook(() =>
      useWhiteboardCollaboration("conversation-one")
    );
    await waitFor(() => expect(result.current.initialElements).toEqual([]));

    vi.useFakeTimers();
    act(() => result.current.armLocalChanges());
    act(() => result.current.handleEditorChange([element("local-element", 1, 8)] as never));
    await act(async () => vi.advanceTimersByTimeAsync(350));
    expect(mocks.appendWhiteboardSceneUpdate).toHaveBeenCalledTimes(1);

    let clearing: Promise<void> | undefined;
    act(() => {
      clearing = result.current.clearBoard();
    });
    await Promise.resolve();
    expect(mocks.clearWhiteboard).not.toHaveBeenCalled();

    await act(async () => {
      resolveSave?.();
      await clearing;
    });
    expect(mocks.clearWhiteboard).toHaveBeenCalledTimes(1);
  });

  it("restores durable history without waiting for the realtime channel", async () => {
    mocks.connect.mockReturnValue(new Promise(() => undefined));

    const { result } = renderHook(() =>
      useWhiteboardCollaboration("conversation-one")
    );

    await waitFor(() => expect(result.current.initialElements).toEqual([]));
    expect(mocks.whiteboardOperations).toHaveBeenCalledWith(
      "conversation-one",
      0
    );
    expect(result.current.connectionStatus).toBe("connecting");
  });

  it("does not persist Excalidraw's durable-scene initialization as a local edit", async () => {
    const restored = element("restored-element", 4, 400);
    mocks.whiteboardOperations.mockResolvedValue({
      data: [operation("restored", [restored])],
      page: { has_more: false, next_after_sequence: 1 }
    });

    const { result } = renderHook(() =>
      useWhiteboardCollaboration("conversation-one")
    );
    await waitFor(() => expect(result.current.initialElements).toEqual([restored]));

    vi.useFakeTimers();
    act(() => result.current.handleEditorChange([restored] as never));
    await act(async () => vi.advanceTimersByTimeAsync(1_000));
    expect(mocks.appendWhiteboardSceneUpdate).not.toHaveBeenCalled();

    const edited = element("restored-element", 5, 500);
    act(() => result.current.armLocalChanges());
    act(() => result.current.handleEditorChange([edited] as never));
    await act(async () => vi.advanceTimersByTimeAsync(350));
    expect(mocks.appendWhiteboardSceneUpdate).toHaveBeenCalledWith(
      "conversation-one",
      expect.any(String),
      1,
      [edited]
    );
  });

  it("replays an authoritative clear after a stale save without retrying erased elements", async () => {
    const erased = element("erased-element", 7, 700);
    mocks.whiteboardOperations
      .mockResolvedValueOnce({
        data: [operation("initial", [erased], "scene.update", "user-two", 1)],
        page: { has_more: false, next_after_sequence: 1 }
      })
      .mockResolvedValueOnce({
        data: [],
        page: { has_more: false, next_after_sequence: 1 }
      })
      .mockResolvedValueOnce({
        data: [operation("clear", [], "board.clear", "user-two", 2)],
        page: { has_more: false, next_after_sequence: 2 }
      })
      .mockResolvedValue({
        data: [],
        page: { has_more: false, next_after_sequence: 2 }
      });
    mocks.appendWhiteboardSceneUpdate.mockRejectedValue(
      new ApiError(
        409,
        "stale_whiteboard_generation",
        "The whiteboard was cleared after this edit began"
      )
    );

    const { result } = renderHook(() =>
      useWhiteboardCollaboration("conversation-one")
    );
    await waitFor(() => expect(result.current.initialElements).toEqual([erased]));
    await waitFor(() => expect(mocks.whiteboardOperations).toHaveBeenCalledTimes(2));

    vi.useFakeTimers();
    const delayedEdit = element("erased-element", 8, 800);
    act(() => result.current.armLocalChanges());
    act(() => result.current.handleEditorChange([delayedEdit] as never));
    await act(async () => vi.advanceTimersByTimeAsync(350));
    await act(async () => vi.advanceTimersByTimeAsync(0));

    expect(mocks.appendWhiteboardSceneUpdate).toHaveBeenCalledTimes(1);
    expect(mocks.whiteboardOperations).toHaveBeenCalledTimes(4);
    expect(result.current.initialElements).toEqual([]);

    act(() => result.current.handleEditorChange([delayedEdit] as never));
    await act(async () => vi.advanceTimersByTimeAsync(2_500));
    expect(mocks.appendWhiteboardSceneUpdate).toHaveBeenCalledTimes(1);
  });

  it("closes a realtime sequence gap from durable history before applying later updates", async () => {
    const { result } = renderHook(() =>
      useWhiteboardCollaboration("conversation-one")
    );
    await waitFor(() => expect(result.current.initialElements).toEqual([]));
    await waitFor(() => expect(mocks.whiteboardOperations).toHaveBeenCalledTimes(2));

    const updateScene = vi.fn();
    const editor = {
      updateScene,
      resetScene: vi.fn(),
      getSceneElementsIncludingDeleted: vi.fn(() => []),
      getAppState: vi.fn(() => ({ selectedElementIds: {} }))
    };
    await act(async () => {
      result.current.attachEditor(editor as never);
      await new Promise<void>((resolve) =>
        window.requestAnimationFrame(() => resolve())
      );
    });

    const first = element("first-element", 1, 100);
    const second = element("second-element", 1, 200);
    mocks.whiteboardOperations.mockResolvedValueOnce({
      data: [operation("first", [first], "scene.update", "user-two", 1)],
      page: { has_more: false, next_after_sequence: 1 }
    });

    act(() =>
      mocks.callbacks?.onOperation(
        operation("second", [second], "scene.update", "user-two", 2)
      )
    );

    await waitFor(() => expect(mocks.whiteboardOperations).toHaveBeenCalledTimes(3));
    await waitFor(() => expect(result.current.elementCount).toBe(2));
    expect(
      updateScene.mock.calls.filter(([scene]) => "elements" in scene)
    ).toHaveLength(2);
  });
});

function element(id: string, version: number, versionNonce: number) {
  return {
    id,
    type: "rectangle",
    version,
    versionNonce,
    isDeleted: false,
    link: null,
    customData: null
  };
}

function operation(
  clientOperationId: string,
  elements: unknown[],
  kind: "scene.update" | "board.clear" = "scene.update",
  actorUserId = "user-one",
  sequence = 1
): WhiteboardOperation {
  return {
    id: `operation-${clientOperationId}`,
    whiteboard_id: "whiteboard-one",
    tenant_id: "tenant-one",
    conversation_id: "conversation-one",
    actor_user_id: actorUserId,
    client_operation_id: clientOperationId,
    sequence,
    kind,
    payload: kind === "scene.update" ? { elements: elements as never[] } : {},
    inserted_at: "2026-08-01T12:00:00Z"
  };
}
