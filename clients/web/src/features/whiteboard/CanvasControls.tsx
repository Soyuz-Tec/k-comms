import type {
  ExcalidrawImperativeAPI,
  NormalizedZoomValue
} from "@excalidraw/excalidraw/types";
import { createPortal } from "react-dom";
import { useEffect, useId, useRef, useState, type CSSProperties } from "react";
import { AppIcon } from "../../components/AppIcon";
import { useModalDialog } from "../../components/useModalDialog";
import { CanvasTemplateDialog } from "./CanvasTemplateDialog";
import { createCanvasTemplateElements } from "./canvasTemplates";
import "./CanvasControls.css";

const canvasBackgrounds = [
  { color: "#ffffff", label: "White" },
  { color: "#f8f9fa", label: "Soft gray" },
  { color: "#fff9db", label: "Warm" },
  { color: "#e7f5ff", label: "Blue" }
] as const;

function normalizedZoom(value: number): NormalizedZoomValue {
  return Math.min(3, Math.max(0.1, value)) as NormalizedZoomValue;
}

export function CanvasControls({
  editor,
  elementCount,
  clearRequestId = 0,
  onClearCanvas,
  onMessageSelection,
  shared = false,
  selectedCount = 0
}: {
  editor: ExcalidrawImperativeAPI | null;
  elementCount: number;
  clearRequestId?: number;
  onClearCanvas: () => Promise<void> | void;
  onMessageSelection?: () => void;
  shared?: boolean;
  selectedCount?: number;
}) {
  const controlsId = useId();
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const panelRef = useRef<HTMLDivElement | null>(null);
  const [open, setOpen] = useState(false);
  const [templatesOpen, setTemplatesOpen] = useState(false);
  const [confirmClear, setConfirmClear] = useState(false);
  const [clearing, setClearing] = useState(false);
  const [clearError, setClearError] = useState("");
  const [theme, setTheme] = useState<"light" | "dark">("light");
  const [background, setBackground] = useState("#ffffff");
  const [zoom, setZoom] = useState(1);
  const clearDialogRef = useModalDialog(
    () => {
      if (!clearing) setConfirmClear(false);
    },
    confirmClear
  );

  useEffect(() => {
    if (clearRequestId > 0) {
      setOpen(false);
      setClearError("");
      setConfirmClear(true);
    }
  }, [clearRequestId]);

  function syncEditorState() {
    if (!editor) return;
    const appState = editor.getAppState();
    setTheme(appState.theme === "dark" ? "dark" : "light");
    setBackground(appState.viewBackgroundColor || "#ffffff");
    setZoom(appState.zoom.value);
  }

  useEffect(() => {
    if (!open) return;
    syncEditorState();

    function closeFromOutside(event: PointerEvent) {
      const target = event.target;
      if (!(target instanceof Node)) return;
      if (!panelRef.current?.contains(target) && !triggerRef.current?.contains(target)) {
        setOpen(false);
      }
    }

    function closeFromEscape(event: KeyboardEvent) {
      if (event.key !== "Escape") return;
      event.preventDefault();
      setOpen(false);
      triggerRef.current?.focus();
    }

    document.addEventListener("pointerdown", closeFromOutside);
    document.addEventListener("keydown", closeFromEscape, true);
    return () => {
      document.removeEventListener("pointerdown", closeFromOutside);
      document.removeEventListener("keydown", closeFromEscape, true);
    };
  }, [editor, open]);

  function applyZoom(value: number) {
    if (!editor) return;
    const next = normalizedZoom(value);
    editor.updateScene({ appState: { zoom: { value: next } } });
    setZoom(next);
  }

  function applyTheme(nextTheme: "light" | "dark") {
    if (!editor) return;
    editor.updateScene({ appState: { theme: nextTheme } });
    setTheme(nextTheme);
  }

  function applyBackground(color: string) {
    if (!editor) return;
    editor.updateScene({ appState: { viewBackgroundColor: color } });
    setBackground(color);
  }

  async function clearCanvas() {
    setClearing(true);
    setClearError("");
    try {
      await onClearCanvas();
      setConfirmClear(false);
    } catch (reason: unknown) {
      setClearError(
        reason instanceof Error
          ? reason.message
          : "The canvas could not be cleared. Try again."
      );
    } finally {
      setClearing(false);
    }
  }

  async function applyTemplate(templateId: string) {
    if (!editor) return;
    const existing = editor.getSceneElements();
    const inserted = await createCanvasTemplateElements(templateId, existing);
    if (inserted.length === 0) return;
    editor.updateScene({ elements: [...existing, ...inserted] });
    editor.scrollToContent(inserted, {
      animate: true,
      fitToViewport: true,
      viewportZoomFactor: 0.82
    });
    closeTemplates();
  }

  function closeTemplates() {
    setTemplatesOpen(false);
    window.requestAnimationFrame(() => triggerRef.current?.focus());
  }

  return (
    <>
      <div className="canvas-controls">
        <button
          ref={triggerRef}
          className="canvas-controls-trigger"
          type="button"
          aria-label="Open canvas controls"
          aria-haspopup="dialog"
          aria-expanded={open}
          aria-controls={controlsId}
          title="Canvas controls"
          onClick={() => setOpen((current) => !current)}
        >
          <AppIcon name="sliders" />
          <span className="canvas-controls-count" aria-hidden="true">{elementCount}</span>
        </button>

        {open && (
          <div
            ref={panelRef}
            className="canvas-controls-panel"
            id={controlsId}
            role="dialog"
            aria-label="Canvas controls"
          >
            <header>
              <div>
                <span>Canvas</span>
                <strong>Canvas controls</strong>
              </div>
              <button
                type="button"
                aria-label="Close canvas controls"
                onClick={() => {
                  setOpen(false);
                  triggerRef.current?.focus();
                }}
              >
                <AppIcon name="x" />
              </button>
            </header>

            <section aria-labelledby={`${controlsId}-appearance`}>
              <button
                className="canvas-template-launch"
                type="button"
                disabled={!editor}
                onClick={() => {
                  setOpen(false);
                  setTemplatesOpen(true);
                }}
              >
                <span className="canvas-template-launch-icon"><AppIcon name="sparkles" /></span>
                <span>
                  <strong>Start with a template</strong>
                  <small>Brainstorms, plans, retrospectives, and more</small>
                </span>
                <AppIcon name="arrowUpRight" />
              </button>

              <h2 id={`${controlsId}-appearance`}>Appearance</h2>
              <div className="canvas-controls-segmented" role="group" aria-label="Canvas theme">
                <button
                  type="button"
                  aria-pressed={theme === "light"}
                  disabled={!editor}
                  onClick={() => applyTheme("light")}
                >
                  Light
                </button>
                <button
                  type="button"
                  aria-pressed={theme === "dark"}
                  disabled={!editor}
                  onClick={() => applyTheme("dark")}
                >
                  Dark
                </button>
              </div>
              <div className="canvas-background-options" role="group" aria-label="Canvas background">
                {canvasBackgrounds.map((option) => (
                  <button
                    key={option.color}
                    type="button"
                    aria-label={`${option.label} canvas background`}
                    aria-pressed={background.toLowerCase() === option.color}
                    disabled={!editor}
                    style={{ "--canvas-swatch": option.color } as CSSProperties}
                    onClick={() => applyBackground(option.color)}
                  >
                    <span aria-hidden="true" />
                    {option.label}
                  </button>
                ))}
              </div>
            </section>

            <section aria-labelledby={`${controlsId}-view`}>
              <h2 id={`${controlsId}-view`}>View</h2>
              <div className="canvas-view-controls" role="group" aria-label="Canvas zoom">
                <button
                  type="button"
                  aria-label="Zoom out"
                  disabled={!editor}
                  onClick={() => applyZoom(zoom / 1.2)}
                >
                  −
                </button>
                <button
                  type="button"
                  aria-label="Reset zoom"
                  disabled={!editor}
                  onClick={() => applyZoom(1)}
                >
                  {Math.round(zoom * 100)}%
                </button>
                <button
                  type="button"
                  aria-label="Zoom in"
                  disabled={!editor}
                  onClick={() => applyZoom(zoom * 1.2)}
                >
                  +
                </button>
                <button
                  type="button"
                  disabled={!editor || elementCount === 0}
                  onClick={() => {
                    editor?.scrollToContent(undefined, {
                      animate: true,
                      fitToViewport: true,
                      viewportZoomFactor: 0.85
                    });
                    window.setTimeout(syncEditorState, 250);
                  }}
                >
                  Fit canvas
                </button>
              </div>
            </section>

            {onMessageSelection && selectedCount > 0 && (
              <section aria-labelledby={`${controlsId}-selection`}>
                <h2 id={`${controlsId}-selection`}>Selection</h2>
                <button
                  className="canvas-controls-action"
                  type="button"
                  onClick={() => {
                    onMessageSelection();
                    setOpen(false);
                  }}
                >
                  <AppIcon name="message" />
                  <span>
                    <strong>Message selection</strong>
                    <small>{selectedCount} selected {selectedCount === 1 ? "object" : "objects"}</small>
                  </span>
                </button>
              </section>
            )}

            <section className="canvas-controls-danger" aria-labelledby={`${controlsId}-canvas-data`}>
              <h2 id={`${controlsId}-canvas-data`}>Canvas data</h2>
              <button
                className="canvas-controls-action"
                type="button"
                disabled={elementCount === 0}
                onClick={() => {
                  triggerRef.current?.focus();
                  setOpen(false);
                  setClearError("");
                  setConfirmClear(true);
                }}
              >
                <AppIcon name="trash" />
                <span>
                  <strong>Clear canvas</strong>
                  <small>
                    {elementCount === 0
                      ? "The canvas is already empty."
                      : `Remove ${elementCount} ${elementCount === 1 ? "object" : "objects"}.`}
                  </small>
                </span>
              </button>
            </section>
          </div>
        )}
      </div>

      {templatesOpen && (
        <CanvasTemplateDialog
          elementCount={elementCount}
          onApply={applyTemplate}
          onClose={closeTemplates}
        />
      )}

      {confirmClear && createPortal(
        <div className="canvas-clear-backdrop">
          <section
            ref={clearDialogRef}
            className="canvas-clear-dialog"
            role="alertdialog"
            aria-modal="true"
            aria-labelledby={`${controlsId}-clear-title`}
            aria-describedby={`${controlsId}-clear-description`}
            aria-busy={clearing}
            tabIndex={-1}
          >
            <h2 id={`${controlsId}-clear-title`}>Clear this canvas?</h2>
            <p id={`${controlsId}-clear-description`}>
              {shared
                ? "This removes every canvas object for everyone currently viewing this room."
                : "This removes every canvas object from the local draft in this browser."}
            </p>
            {clearError && <p className="canvas-clear-error" role="alert">{clearError}</p>}
            <div className="canvas-clear-actions">
              <button
                data-initial-focus
                className="button ghost"
                type="button"
                disabled={clearing}
                onClick={() => setConfirmClear(false)}
              >
                Cancel
              </button>
              <button
                className="button danger"
                type="button"
                disabled={clearing}
                onClick={() => void clearCanvas()}
              >
                {clearing ? "Clearing…" : "Clear canvas"}
              </button>
            </div>
          </section>
        </div>,
        document.body
      )}
    </>
  );
}
