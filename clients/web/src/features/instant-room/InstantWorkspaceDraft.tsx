import type { ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types";
import type { ExcalidrawElement } from "@excalidraw/excalidraw/element/types";
import { useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import { Link } from "react-router";
import { AppIcon } from "../../components/AppIcon";
import { useModalDialog } from "../../components/useModalDialog";
import type { WhiteboardElementData } from "../../types";
import { CanvasControls } from "../whiteboard/CanvasControls";
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
  intent: "message" | "room";
  messageClientId: string;
  whiteboardOperationId: string;
}

export function InstantWorkspaceDraft({
  activating,
  error,
  identityManaged,
  initialDisplayName,
  retrySeconds,
  onActivate
}: {
  activating: boolean;
  error: string;
  identityManaged: boolean;
  initialDisplayName?: string;
  retrySeconds: number;
  onActivate: (request: DraftActivationRequest) => Promise<boolean>;
}) {
  const generatedGuestNameRef = useRef("");
  if (!generatedGuestNameRef.current) {
    generatedGuestNameRef.current = defaultGuestDisplayName();
  }
  const fallbackDisplayName =
    initialDisplayName?.trim() || generatedGuestNameRef.current;
  const [draft, setDraft] = useState<InstantWorkspaceDraftRecord>(() => {
    const restored = loadInstantWorkspaceDraft(fallbackDisplayName);
    return identityManaged
      ? { ...restored, displayName: fallbackDisplayName }
      : restored;
  });
  const [message, setMessage] = useState("");
  const [elementCount, setElementCount] = useState(draft.elements.length);
  const [mobileView, setMobileView] = useState<"canvas" | "room">("canvas");
  const [showClearConfirmation, setShowClearConfirmation] = useState(false);
  const [showHint, setShowHint] = useState(() => {
    try {
      return window.localStorage.getItem(hintStorageKey) !== "dismissed";
    } catch {
      return true;
    }
  });
  const [nameError, setNameError] = useState("");
  const [editor, setEditor] = useState<ExcalidrawImperativeAPI | null>(null);
  const editorRef = useRef<ExcalidrawImperativeAPI | null>(null);
  const draftRef = useRef(draft);
  const pendingSaveRef = useRef<number | null>(null);
  const createRoomRef = useRef<HTMLButtonElement | null>(null);
  const clearDialogRef = useModalDialog(
    () => setShowClearConfirmation(false),
    showClearConfirmation
  );

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
      setMobileView("room");
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

  function clearDraft() {
    const next = newInstantWorkspaceDraft(
      identityManaged
        ? fallbackDisplayName
        : draftRef.current.displayName.trim() || fallbackDisplayName
    );
    draftRef.current = next;
    setDraft(next);
    setElementCount(0);
    setMessage("");
    setNameError("");
    setShowClearConfirmation(false);
    editorRef.current?.resetScene();
    saveInstantWorkspaceDraft(next);
    window.requestAnimationFrame(() => createRoomRef.current?.focus());
  }

  function clearCanvas() {
    const next = {
      ...draftRef.current,
      elements: [],
      updatedAt: new Date().toISOString()
    };
    draftRef.current = next;
    setDraft(next);
    setElementCount(0);
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
  const hasDraftWork =
    elementCount > 0 || Boolean(message.trim()) || Boolean(draft.roomTitle.trim());

  return (
    <section
      className="instant-draft"
      aria-labelledby="instant-draft-title"
      aria-busy={activating}
    >
      <h1 id="instant-draft-title" className="sr-only" data-route-focus>
        Message. Draw. Share.
      </h1>

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
          aria-pressed={mobileView === "room"}
          onClick={() => setMobileView("room")}
        >
          <AppIcon name="users" /> Room
        </button>
      </div>

      <div className="instant-draft-body" data-mobile-view={mobileView}>
        <div className="instant-draft-canvas" aria-label="Local drawing canvas">
          {showHint && (
            <aside className="instant-draft-hint" aria-label="Drawing tip">
              <div>
                <strong>Start anywhere</strong>
                <span>Choose a tool and draw. This draft stays in this browser for up to 24 hours.</span>
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
              setEditor(editor);
            }}
            onChange={updateElements}
            onLinkOpen={(_element, event) => event.preventDefault()}
            validateEmbeddable={false}
          />
          <CanvasControls
            editor={editor}
            elementCount={elementCount}
            onClearCanvas={clearCanvas}
          />
        </div>

        <aside className="instant-draft-chat" aria-label="Room setup">
          <div className="instant-draft-setup-scroll">
            <div className="instant-draft-chat-heading">
              <span className="instant-draft-chat-icon"><AppIcon name="users" /></span>
              <div>
                <h2>Create a room</h2>
                <p>Confirm who you are, then open the collaboration controls.</p>
              </div>
            </div>

            <ol className="instant-draft-workflow" aria-label="Collaboration workflow">
              <li className="current" aria-current="step"><span>1</span> Your name</li>
              <li><span>2</span> Create room</li>
              <li><span>3</span> Invite &amp; call</li>
            </ol>

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

            <form className="instant-draft-composer" onSubmit={(event) => void sendMessage(event)}>
              <label htmlFor="instant-draft-message">Optional first message</label>
              <div className="composer-shell">
                <textarea
                  id="instant-draft-message"
                  value={message}
                  maxLength={10_000}
                  rows={1}
                  disabled={activating}
                  placeholder="Add a message to send when the room opens…"
                  onChange={(event) => setMessage(event.target.value)}
                  onKeyDown={(event) => {
                    if (
                      event.key === "Enter" &&
                      !event.shiftKey &&
                      !event.nativeEvent.isComposing
                    ) {
                      event.preventDefault();
                      event.currentTarget.form?.requestSubmit();
                    }
                  }}
                />
                <div className="composer-inline-actions">
                  <button
                    className="composer-icon-button composer-send send-button"
                    type="submit"
                    aria-label="Create & send"
                    title="Create room and send message"
                    disabled={!message.trim() || blocked}
                  >
                    <AppIcon name="send" />
                  </button>
                </div>
              </div>
              <p className="composer-footnote">
                <span>Enter to send · Shift+Enter for a new line</span>
              </p>
            </form>

            {hasDraftWork && (
              <button
                className="instant-draft-clear"
                type="button"
                disabled={activating}
                onClick={() => setShowClearConfirmation(true)}
              >
                Clear local draft
              </button>
            )}
          </div>

          <div className="instant-draft-live-actions">
            <button
              ref={createRoomRef}
              className="button primary full instant-draft-start"
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
                    : "Create room"}
            </button>
            <small>Invite links, QR sharing, audio, and video appear inside the room.</small>
            <Link className="instant-draft-account-link" to={identityManaged ? "/app/" : "/sign-in"}>
              {identityManaged ? "Open your full workspace" : "Already have an account? Sign in"}
            </Link>
          </div>
        </aside>
      </div>

      {showClearConfirmation && (
        <div className="instant-draft-dialog-backdrop">
          <section
            ref={clearDialogRef}
            className="instant-draft-dialog"
            role="dialog"
            aria-modal="true"
            aria-labelledby="instant-draft-clear-title"
            aria-describedby="instant-draft-clear-description"
            tabIndex={-1}
          >
            <h2 id="instant-draft-clear-title">Clear this local draft?</h2>
            <p id="instant-draft-clear-description">
              The room name, unsent message, and canvas objects in this browser will be removed.
            </p>
            <div>
              <button
                data-initial-focus
                className="button ghost"
                type="button"
                onClick={() => setShowClearConfirmation(false)}
              >
                Cancel
              </button>
              <button className="button danger" type="button" onClick={clearDraft}>
                Clear local draft
              </button>
            </div>
          </section>
        </div>
      )}
    </section>
  );
}
