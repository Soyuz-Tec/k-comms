import { render, screen } from "@testing-library/react";
import type { CSSProperties, ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  isBlockedDrawingShortcut,
  KCommsDrawingCanvas
} from "./KCommsDrawingCanvas";

const drawingEngineHarness = vi.hoisted(() => ({
  props: null as null | Record<string, unknown>
}));

vi.mock("@excalidraw/excalidraw", () => {
  function MainMenu({ children }: { children?: ReactNode }) {
    return <div aria-label="K-Comms canvas menu">{children}</div>;
  }

  MainMenu.DefaultItems = {
    ToggleTheme: () => <button type="button">Theme</button>,
    ChangeCanvasBackground: () => (
      <button type="button">Canvas background</button>
    )
  };

  const DefaultSidebar = {
    Trigger: (props: Record<string, unknown>) => (
      <button
        aria-hidden={props["aria-hidden"] as boolean}
        data-testid="drawing-sidebar-trigger"
        style={props.style as CSSProperties}
        type="button"
      />
    )
  };

  return {
    DefaultSidebar,
    Excalidraw: ({
      children,
      ...props
    }: {
      children?: ReactNode;
      [key: string]: unknown;
    }) => {
      drawingEngineHarness.props = props;
      return (
        <div aria-label="Drawing engine test surface">
          <button data-testid="main-menu-trigger" type="button" />
          {children}
        </div>
      );
    },
    MainMenu
  };
});

describe("KCommsDrawingCanvas", () => {
  beforeEach(() => {
    drawingEngineHarness.props = null;
  });

  it("owns a minimal K-Comms menu and disables vendor-owned external flows", () => {
    render(
      <KCommsDrawingCanvas
        UIOptions={{
          canvasActions: {
            clearCanvas: true,
            export: {},
            loadScene: true,
            saveAsImage: true,
            saveToActiveFile: true
          },
          tools: { image: true }
        }}
      />
    );

    expect(screen.getByLabelText("K-Comms canvas menu")).toBeVisible();
    expect(
      screen.getByRole("button", { name: "Canvas settings" })
    ).toHaveAttribute("title", "Canvas settings");
    expect(screen.getByRole("button", { name: "Theme" })).toBeVisible();
    expect(
      screen.getByRole("button", { name: "Canvas background" })
    ).toBeVisible();
    expect(screen.getByTestId("drawing-sidebar-trigger")).not.toBeVisible();
    expect(drawingEngineHarness.props?.UIOptions).toEqual({
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
    });
  });

  it("blocks shortcuts that can reopen vendor help or command surfaces", () => {
    expect(
      isBlockedDrawingShortcut({
        key: "?",
        ctrlKey: false,
        metaKey: false,
        shiftKey: true
      })
    ).toBe(true);
    expect(
      isBlockedDrawingShortcut({
        key: "p",
        ctrlKey: true,
        metaKey: false,
        shiftKey: true
      })
    ).toBe(true);
    expect(
      isBlockedDrawingShortcut({
        key: "r",
        ctrlKey: false,
        metaKey: false,
        shiftKey: false
      })
    ).toBe(false);
  });
});
