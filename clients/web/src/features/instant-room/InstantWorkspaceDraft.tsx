import type { ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types";
import type { ExcalidrawElement } from "@excalidraw/excalidraw/element/types";
import { useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import { AppIcon } from "../../components/AppIcon";
import type { WhiteboardElementData } from "../../types";
import { KCommsDrawingCanvas } from "../whiteboard/KCommsDrawingCanvas";
import {
  defaultGuestDisplayName,
  loadInstantWorkspaceDraft,
  newInstantWorkspaceDraft,
  saveInstantWorkspaceDraft,
  type InstantWorkspaceDraftRecord
} from "./instantWorkspaceDraftStore";
import "./InstantWorkspaceDraft.css";

const hintStorageKey = "k-comms.instant-workspace-hint.v1";

export interface DraftActivationRequest {
  displayName: string;
  roomTitle: string;
  elements: WhiteboardElementData[];
  initialMessage?: string;
  intent: "message" | "room" | "share" | "audio-call" | "video-call";
  messageClientId: string;
  whiteboardOperationId: string;
}

export function InstantWorkspaceDraft({
  activating,
  error,
  identityManaged,
  initialDisplayName,
  mediaActionsAllowed,
  retrySeconds,
  onActivate
}: {
  activating: boolean;
  error: string;
  identityManaged: boolean;
  initialDisplayName?: string;
  mediaActionsAllowed: boolean;
  retrySeconds: number;
  onActivate: (request: DraftActivationRequest) => Promise<boolean>;
}) {
  const fallbackDisplayName =
    initialDisplayName?.trim() || defaultGuestDisplayName();
  const [draft, setDraft] = useState<InstantWorkspaceDraftRecord>(() => {
    const restored = loadInstantWorkspaceDraft(fallbackDisplayName);
    return identityManaged
      ? { ...restored, displayName: fallbackDisplayName }
      : restored;
  });
  const [message, setMessage] = useState("");
  const [elementCount, setElementCount] = useState(draft.elements.length);
  const [mobileView, setMobileView] = useState<"canvas" | "messages">(
    "canvas"
  );
  const [showHint, setShowHint] = useState(() => {
    try {
      return window.localStorage.getItem(hintStorageKey) !== "dismissed";
    } catch {
      return true;
    }
  });
  const [nameError, setNameError] = useState("");
  const editorRef = useRef<ExcalidrawImperativeAPI | null>(null);
  const draftRef = useRef(draft);
  const pendingSaveRef = useRef<number | null>(null);

  useEffect(
    () => () => {
      if (pendingSaveRef.current !== null) {
        window.clearTimeout(pendingSaveRef.current);
        saveInstantWorkspaceDraft(draftRef.current);
      }
    },
    []
  );

  useEffect(() => {
    const managedName = initialDisplayName?.trim();
    if (
      identityManaged &&
      managedName &&
      draftRef.current.displayName !== managedName
    ) {
      updateDraft({ displayName: managedName });
    }
  }, [identityManaged, initialDisplayName]);

  function updateDraft(patch: Partial<InstantWorkspaceDraftRecord>) {
    const next = {
      ...draftRef.current,
      ...patch,
      updatedAt: new Date().toISOString()
    };
    draftRef.current = next;
    setDraft(next);
    saveInstantWorkspaceDraft(next);
  }

  function updateElements(elements: readonly ExcalidrawElement[]) {
    const portable = elements
      .filter((element) => element.isDeleted !== true)
      .map((element) => ({ ...element })) as unknown as WhiteboardElementData[];
    setElementCount(portable.length);
    draftRef.current = {
      ...draftRef.current,
      elements: portable,
      updatedAt: new Date().toISOString()
    };
    if (pendingSaveRef.current !== null) {
      window.clearTimeout(pendingSaveRef.current);
    }
    pendingSaveRef.current = window.setTimeout(() => {
      pendingSaveRef.current = null;
      saveInstantWorkspaceDraft(draftRef.current);
    }, 300);
  }

  async function activate(
    intent: DraftActivationRequest["intent"],
    initialMessage?: string
  ) {
    const displayName = draftRef.current.displayName.trim();
    if (!displayName) {
      setNameError("Enter your display name to continue.");
      setMobileView("messages");
      document.getElementById("instant-draft-display-name")?.focus();
      return false;
    }
    setNameError("");
    return onActivate({
      displayName,
      roomTitle: draftRef.current.roomTitle.trim(),
      elements: draftRef.current.elements,
      initialMessage: initialMessage?.trim() || undefined,
      intent,
      messageClientId: draftRef.current.messageClientId,
      whiteboardOperationId: draftRef.current.whiteboardOperationId
    });
  }

  async function sendMessage(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!message.trim() || activating || retrySeconds > 0) return;
    await activate("message", message);
  }

  function startNewDraft() {
    const next = newInstantWorkspaceDraft(
      identityManaged ? fallbackDisplayName : defaultGuestDisplayName()
    );
    draftRef.current = next;
    setDraft(next);
    setElementCount(0);
    setMessage("");
    setNameError("");
    editorRef.current?.resetScene();
    saveInstantWorkspaceDraft(next);
  }

  function dismissHint() {
    setShowHint(false);
    try {
      window.localStorage.setItem(hintStorageKey, "dismissed");
    } catch {
      // The hint can still be dismissed for the current render.
    }
  }

  const blocked = activating || retrySeconds > 0;

  return (
    <section
      className="instant-draft"
      aria-labelledby="instant-draft-title"
      aria-busy={activating}
    >
      <header className="instant-draft-toolbar">
        <div className="instant-draft-title-group">
          <span className="instant-draft-status">
            <span aria-hidden="true" /> Private draft
          </span>
          <div>
            <h1 id="instant-draft-title" data-route-focus>
              Message. Draw. Share.
            </h1>
            <p>Draw immediately. A durable room starts only when you message or share.</p>
          </div>
        </div>
        <div className="instant-draft-actions" role="group" aria-label="Workspace actions">
          <button className="button ghost" type="button" onClick={startNewDraft} disabled={activating}>
            <AppIcon name="plus" /> New
          </button>
          <button
            className="button primary"
            type="button"
            disabled={blocked}
            onClick={() => void activate("share")}
          >
            <AppIcon name="share" />
            {activating
              ? "Opening…"
              : retrySeconds > 0
                ? `Retry in ${retrySeconds}s`
                : "Share"}
          </button>
        </div>
      </header>

      {error && (
        <div className="instant-draft-error" role="alert">
          <AppIcon name="triangleAlert" />
          <span>{error}</span>
        </div>
      )}
      <span className="sr-only" role="status" aria-live="polite">
        {activating ? "Opening your room. Please wait." : ""}
      </span>

      <div className="instant-draft-mobile-tabs" role="group" aria-label="Workspace tools">
        <button
          className="button ghost"
          type="button"
          aria-pressed={mobileView === "canvas"}
          onClick={() => setMobileView("canvas")}
        >
          <AppIcon name="whiteboard" /> Canvas
        </button>
        <button
          className="button ghost"
          type="button"
          aria-pressed={mobileView === "messages"}
          onClick={() => setMobileView("messages")}
        >
          <AppIcon name="messages" /> Messages
        </button>
      </div>

      <div className="instant-draft-body" data-mobile-view={mobileView}>
        <div className="instant-draft-canvas" aria-label="Private drawing canvas">
          {showHint && (
            <aside className="instant-draft-hint" aria-label="Drawing tip">
              <div>
                <strong>Start anywhere</strong>
                <span>Choose a tool and draw. Your private draft stays on this device.</span>
              </div>
              <button type="button" aria-label="Dismiss drawing tip" onClick={dismissHint}>
                <AppIcon name="x" />
              </button>
            </aside>
          )}
          <KCommsDrawingCanvas
            initialData={{
              elements: draft.elements as never,
              appState: { name: draft.roomTitle || "K-Comms workspace" }
            }}
            excalidrawAPI={(editor) => {
              editorRef.current = editor;
            }}
            onChange={updateElements}
            onLinkOpen={(_element, event) => event.preventDefault()}
            validateEmbeddable={false}
          />
        </div>

        <aside className="instant-draft-chat" aria-label="Workspace messages">
          <div className="instant-draft-chat-heading">
            <span className="instant-draft-chat-icon"><AppIcon name="messages" /></span>
            <div>
              <h2>Messages</h2>
              <p>Your first message starts the live room and preserves this canvas.</p>
            </div>
          </div>

          <div className="instant-draft-room-details">
            <div className="field">
              <label htmlFor="instant-draft-display-name">
                Your display name <span aria-hidden="true">Required</span>
              </label>
              <input
                id="instant-draft-display-name"
                name="display_name"
                type="text"
                maxLength={120}
                autoComplete="name"
                value={draft.displayName}
                disabled={identityManaged || activating}
                aria-invalid={Boolean(nameError)}
                aria-describedby={
                  nameError
                    ? "instant-draft-display-name-help instant-draft-name-error"
                    : "instant-draft-display-name-help"
                }
                onChange={(event) => {
                  updateDraft({ displayName: event.target.value });
                  if (event.target.value.trim()) setNameError("");
                }}
                required
              />
              <small id="instant-draft-display-name-help">
                Visible to everyone in the room.
              </small>
              {nameError && (
                <small
                  id="instant-draft-name-error"
                  className="instant-draft-field-error"
                  role="alert"
                >
                  {nameError}
                </small>
              )}
            </div>
            <div className="field">
              <label htmlFor="instant-draft-room-title">
                Room name <span aria-hidden="true">Optional</span>
              </label>
              <input
                id="instant-draft-room-title"
                name="title"
                type="text"
                maxLength={160}
                autoComplete="off"
                value={draft.roomTitle}
                disabled={activating}
                placeholder="Instant workspace"
                aria-describedby="instant-draft-room-title-help"
                onChange={(event) => updateDraft({ roomTitle: event.target.value })}
              />
              <small id="instant-draft-room-title-help">
                Defaults to “Instant room”.
              </small>
            </div>
          </div>

          <div className="instant-draft-chat-empty">
            <span><AppIcon name="lock" /></span>
            <strong>Nothing has been shared yet</strong>
            <p>Write a message or select Share when you are ready to invite people.</p>
          </div>

          <form className="instant-draft-composer" onSubmit={(event) => void sendMessage(event)}>
            <label className="sr-only" htmlFor="instant-draft-message">Message the room</label>
            <textarea
              id="instant-draft-message"
              value={message}
              maxLength={10_000}
              rows={3}
              disabled={activating}
              placeholder="Message the room…"
              onChange={(event) => setMessage(event.target.value)}
            />
            <div>
              <span>{elementCount} canvas {elementCount === 1 ? "object" : "objects"}</span>
              <button className="button primary" type="submit" disabled={!message.trim() || blocked}>
                <AppIcon name="send" /> Send
              </button>
            </div>
          </form>

          <div className="instant-draft-live-actions">
            <button
              className="button ghost full instant-draft-start"
              type="button"
              disabled={blocked}
              aria-disabled={blocked}
              onClick={() => void activate("room")}
            >
              <AppIcon name="users" />
              {activating
                ? "Opening room…"
                : retrySeconds > 0
                  ? `Try again in ${retrySeconds}s`
                  : error
                    ? "Try again"
                    : "Start instant room"}
            </button>
            <div
              className="instant-draft-call-actions"
              role="group"
              aria-label="Start a call"
              aria-describedby="instant-draft-call-guidance"
            >
              <button
                className="button ghost"
                type="button"
                disabled={blocked || !mediaActionsAllowed}
                onClick={() => void activate("audio-call")}
              >
                <AppIcon name="phone" />
                Start audio call
              </button>
              <button
                className="button ghost"
                type="button"
                disabled={blocked || !mediaActionsAllowed}
                onClick={() => void activate("video-call")}
              >
                <AppIcon name="video" />
                Start video call
              </button>
            </div>
            <small id="instant-draft-call-guidance">
              {mediaActionsAllowed
                ? "K-Comms opens the room first, then lets you choose microphone and camera access before joining."
                : "Calls become available after K-Comms verifies a trusted HTTPS connection."}
            </small>
          </div>
        </aside>
      </div>
    </section>
  );
}
