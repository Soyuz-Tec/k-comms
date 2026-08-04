import {
  DefaultSidebar as DrawingSidebar,
  Excalidraw as DrawingEngine,
  MainMenu as DrawingMenu
} from "@excalidraw/excalidraw";
import "@excalidraw/excalidraw/index.css";
import type { ComponentProps, KeyboardEvent, MouseEvent } from "react";
import { useEffect, useRef } from "react";
import "./KCommsDrawingCanvas.css";

type DrawingEngineProps = ComponentProps<typeof DrawingEngine>;

export type KCommsDrawingCanvasProps = Omit<
  DrawingEngineProps,
  "children" | "UIOptions"
> & {
  UIOptions?: DrawingEngineProps["UIOptions"];
};

export const K_COMMS_DRAWING_UI_OPTIONS = {
  canvasActions: {
    changeViewBackgroundColor: false,
    clearCanvas: false,
    export: false,
    loadScene: false,
    saveAsImage: false,
    saveToActiveFile: false,
    toggleTheme: false
  },
  tools: { image: false }
} as const;

export function isBlockedDrawingShortcut(event: {
  key: string;
  ctrlKey: boolean;
  metaKey: boolean;
  shiftKey: boolean;
}) {
  const commandKey = event.ctrlKey || event.metaKey;

  return (
    event.key === "?" ||
    event.key === "F1" ||
    (commandKey && event.key === "/") ||
    (commandKey && event.shiftKey && event.key.toLowerCase() === "p")
  );
}

function stopVendorHelpAndCommandMenus(event: KeyboardEvent<HTMLDivElement>) {
  if (!isBlockedDrawingShortcut(event)) return;

  event.preventDefault();
  event.stopPropagation();
}

const unsupportedDrawingActions = [
  "image",
  "web embed",
  "embeddable",
  "mermaid to excalidraw",
  "wireframe to code"
] as const;

export function isUnsupportedDrawingActionLabel(label: string) {
  const normalized = label.trim().toLowerCase();
  return unsupportedDrawingActions.some((action) => normalized.includes(action));
}

function actionLabel(element: Element): string {
  return [
    element.getAttribute("aria-label"),
    element.getAttribute("title"),
    element.textContent
  ].filter(Boolean).join(" ");
}

function stopUnsupportedVendorAction(event: MouseEvent<HTMLDivElement>) {
  const target = event.target;
  if (!(target instanceof Element)) return;
  const action = target.closest("button, [role='menuitem']");
  if (!action || !isUnsupportedDrawingActionLabel(actionLabel(action))) return;
  event.preventDefault();
  event.stopPropagation();
}

/**
 * K-Comms' white-label boundary around the replaceable drawing engine.
 *
 * The host owns the visible menu, sharing, persistence, and destructive
 * actions. The SDK remains an implementation detail and must not expose its
 * branded links, help surfaces, public library, or external save/export flows.
 */
export function KCommsDrawingCanvas({
  UIOptions,
  ...drawingProps
}: KCommsDrawingCanvasProps) {
  const drawingSurfaceRef = useRef<HTMLDivElement | null>(null);
  const mergedUIOptions = {
    ...UIOptions,
    canvasActions: {
      ...UIOptions?.canvasActions,
      ...K_COMMS_DRAWING_UI_OPTIONS.canvasActions
    },
    tools: {
      ...UIOptions?.tools,
      ...K_COMMS_DRAWING_UI_OPTIONS.tools
    }
  };

  useEffect(() => {
    const surface = drawingSurfaceRef.current;
    if (!surface) return;

    const enforceHostBoundary = () => {
      const trigger = surface.querySelector<HTMLElement>(
        '[data-testid="main-menu-trigger"]'
      );
      if (trigger) {
        trigger.hidden = true;
        trigger.setAttribute("aria-hidden", "true");
        trigger.tabIndex = -1;
      }

      for (const action of surface.querySelectorAll<HTMLElement>(
        "button, [role='menuitem']"
      )) {
        if (!isUnsupportedDrawingActionLabel(actionLabel(action))) continue;
        action.hidden = true;
        action.setAttribute("aria-hidden", "true");
        action.tabIndex = -1;
      }
    };

    enforceHostBoundary();
    const observer = new MutationObserver(enforceHostBoundary);
    observer.observe(surface, { childList: true, subtree: true });
    return () => observer.disconnect();
  }, []);

  return (
    <div
      ref={drawingSurfaceRef}
      className="k-comms-drawing-surface"
      data-testid="k-comms-drawing-surface"
      onClickCapture={stopUnsupportedVendorAction}
      onKeyDownCapture={stopVendorHelpAndCommandMenus}
    >
      <DrawingEngine {...drawingProps} UIOptions={mergedUIOptions}>
        <DrawingMenu>
          <DrawingMenu.DefaultItems.ToggleTheme />
          <DrawingMenu.DefaultItems.ChangeCanvasBackground />
        </DrawingMenu>
        <DrawingSidebar.Trigger
          aria-hidden="true"
          className="k-comms-hidden-drawing-sidebar-trigger"
          style={{ display: "none" }}
          title="K-Comms canvas resources"
        />
      </DrawingEngine>
    </div>
  );
}
