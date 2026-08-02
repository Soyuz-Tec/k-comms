import {
  DefaultSidebar as DrawingSidebar,
  Excalidraw as DrawingEngine,
  MainMenu as DrawingMenu
} from "@excalidraw/excalidraw";
import "@excalidraw/excalidraw/index.css";
import type { ComponentProps, KeyboardEvent } from "react";
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
    changeViewBackgroundColor: true,
    clearCanvas: false,
    export: false,
    loadScene: false,
    saveAsImage: false,
    saveToActiveFile: false,
    toggleTheme: true
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

  return (
    <div
      className="k-comms-drawing-surface"
      data-testid="k-comms-drawing-surface"
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
