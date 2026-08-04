import type { ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types";
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { CanvasControls } from "./CanvasControls";

function editorHarness() {
  const updateScene = vi.fn();
  const scrollToContent = vi.fn();
  const editor = {
    getAppState: vi.fn(() => ({
      theme: "light",
      viewBackgroundColor: "#ffffff",
      zoom: { value: 1 }
    })),
    scrollToContent,
    updateScene
  } as unknown as ExcalidrawImperativeAPI;
  return { editor, scrollToContent, updateScene };
}

describe("CanvasControls", () => {
  it("owns appearance, view, contextual selection, and destructive canvas actions", async () => {
    const user = userEvent.setup();
    const { editor, scrollToContent, updateScene } = editorHarness();
    const onMessageSelection = vi.fn();
    const onClearCanvas = vi.fn().mockResolvedValue(undefined);

    render(
      <CanvasControls
        editor={editor}
        elementCount={3}
        onClearCanvas={onClearCanvas}
        onMessageSelection={onMessageSelection}
        selectedCount={2}
        shared
      />
    );

    const trigger = screen.getByRole("button", { name: "Open canvas controls" });
    await user.click(trigger);
    const panel = screen.getByRole("dialog", { name: "Canvas controls" });
    expect(within(panel).getByRole("heading", { name: "Appearance" })).toBeVisible();
    expect(within(panel).getByRole("heading", { name: "View" })).toBeVisible();
    expect(within(panel).getByRole("heading", { name: "Selection" })).toBeVisible();
    expect(within(panel).getByRole("heading", { name: "Canvas data" })).toBeVisible();

    await user.click(within(panel).getByRole("button", { name: "Dark" }));
    expect(updateScene).toHaveBeenCalledWith({ appState: { theme: "dark" } });
    await user.click(within(panel).getByRole("button", { name: "Warm canvas background" }));
    expect(updateScene).toHaveBeenCalledWith({
      appState: { viewBackgroundColor: "#fff9db" }
    });
    await user.click(within(panel).getByRole("button", { name: "Zoom in" }));
    expect(updateScene).toHaveBeenCalledWith({
      appState: { zoom: { value: expect.closeTo(1.2) } }
    });
    await user.click(within(panel).getByRole("button", { name: "Fit canvas" }));
    expect(scrollToContent).toHaveBeenCalledWith(undefined, {
      animate: true,
      fitToViewport: true,
      viewportZoomFactor: 0.85
    });

    await user.click(within(panel).getByRole("button", { name: /Message selection/ }));
    expect(onMessageSelection).toHaveBeenCalledOnce();
    expect(screen.queryByRole("dialog", { name: "Canvas controls" })).not.toBeInTheDocument();

    await user.click(trigger);
    await user.click(
      within(screen.getByRole("dialog", { name: "Canvas controls" }))
        .getByRole("button", { name: /Clear canvas/ })
    );
    const confirmation = screen.getByRole("alertdialog", { name: "Clear this canvas?" });
    expect(confirmation).toHaveTextContent("for everyone currently viewing this room");
    await waitFor(() => expect(within(confirmation).getByRole("button", { name: "Cancel" })).toHaveFocus());
    await user.click(within(confirmation).getByRole("button", { name: "Clear canvas" }));
    await waitFor(() => expect(onClearCanvas).toHaveBeenCalledOnce());
    await waitFor(() => expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument());
  });

  it("disables destructive and fit actions for an empty canvas and restores focus on Escape", async () => {
    const user = userEvent.setup();
    const { editor } = editorHarness();

    render(
      <CanvasControls
        editor={editor}
        elementCount={0}
        onClearCanvas={vi.fn()}
      />
    );

    const trigger = screen.getByRole("button", { name: "Open canvas controls" });
    await user.click(trigger);
    const panel = screen.getByRole("dialog", { name: "Canvas controls" });
    expect(within(panel).getByRole("button", { name: "Fit canvas" })).toBeDisabled();
    expect(within(panel).getByRole("button", { name: /Clear canvas/ })).toBeDisabled();
    expect(within(panel).queryByRole("heading", { name: "Selection" })).not.toBeInTheDocument();

    await user.keyboard("{Escape}");
    expect(panel).not.toBeInTheDocument();
    expect(trigger).toHaveFocus();
  });
});
