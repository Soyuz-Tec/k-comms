import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DesktopShellHeader } from "./DesktopShellHeader";
import type { DesktopShellHeaderProps } from "./DesktopShellHeader";
import type { NativeShellAction } from "../lib/desktop-shell";

afterEach(() => { Reflect.deleteProperty(window, "kCommsDesktop"); });

function actions(): DesktopShellHeaderProps {
  return {
    sidebarExpanded: true,
    onToggleSidebar: vi.fn(),
    onNewInstantRoom: vi.fn(),
    onOpenWorkspace: vi.fn(),
    onOpenSearch: vi.fn(),
    onOpenSettings: vi.fn(),
    workspaceName: "Example workspace",
    navigation: { canGoBack: true, canGoForward: false, onBack: vi.fn(), onForward: vi.fn() }
  };
}

describe("DesktopShellHeader browser actions", () => {
  it("can omit repeated workspace identity without closing the active application menu", async () => {
    const props = actions();
    const user = userEvent.setup();
    const { rerender } = render(<DesktopShellHeader {...props} />);
    expect(screen.getByText("Example workspace")).toBeInTheDocument();
    await user.click(screen.getByRole("menuitem", { name: "File" }));
    rerender(<DesktopShellHeader {...props} showWorkspaceName={false} />);
    expect(screen.queryByText("Example workspace")).not.toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "New instant room" })).toHaveFocus();
    await user.click(screen.getByRole("menuitem", { name: "New instant room" }));
    expect(props.onNewInstantRoom).toHaveBeenCalledOnce();
    rerender(<DesktopShellHeader {...props} showWorkspaceName />);
    expect(screen.getByText("Example workspace")).toBeInTheDocument();
    await user.click(screen.getByRole("menuitem", { name: "View" }));
    await user.click(screen.getByRole("menuitem", { name: "Search workspace…" }));
    expect(props.onOpenSearch).toHaveBeenCalledOnce();
  });

  it("uses actual navigation capabilities and provides no browser OS controls or clipboard menu", async () => {
    const props = actions();
    const user = userEvent.setup();
    render(<DesktopShellHeader {...props} />);
    await user.click(screen.getByRole("button", { name: "Go back" }));
    expect(props.navigation!.onBack).toHaveBeenCalledOnce();
    expect(screen.getByRole("button", { name: "Go forward" })).toBeDisabled();
    expect(screen.queryByRole("menuitem", { name: "Edit" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /Minimize|Maximize|Close window/ })).not.toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Toggle workspace navigation" }));
    expect(props.onToggleSidebar).toHaveBeenCalledOnce();
    await user.click(screen.getByRole("menuitem", { name: "File" }));
    await user.click(screen.getByRole("menuitem", { name: "New instant room" }));
    expect(props.onNewInstantRoom).toHaveBeenCalledOnce();
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  });

  it("supports menu keyboard movement, typeahead, Escape and outside dismissal", async () => {
    const user = userEvent.setup();
    const props = actions();
    render(<><DesktopShellHeader {...props} /><input aria-label="Draft" /></>);
    screen.getByRole("menuitem", { name: "File" }).focus();
    await user.keyboard("{ArrowRight}{ArrowDown}");
    expect(screen.getByRole("menuitem", { name: "Use compact navigation" })).toHaveFocus();
    await user.keyboard("s");
    expect(screen.getByRole("menuitem", { name: "Search workspace…" })).toHaveFocus();
    await user.keyboard("{End}");
    expect(screen.getByRole("menuitem", { name: "Your settings" })).toHaveFocus();
    await user.keyboard("{Home}{ArrowUp}");
    expect(screen.getByRole("menuitem", { name: "Your settings" })).toHaveFocus();
    await user.keyboard("{Escape}");
    expect(screen.getByRole("menuitem", { name: "View" })).toHaveFocus();
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    await user.click(screen.getByRole("menuitem", { name: "File" }));
    await user.click(screen.getByRole("textbox", { name: "Draft" }));
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    expect(screen.getByRole("textbox", { name: "Draft" })).toHaveFocus();
  });

  it("shows About with isolated focus and returns to Help after dismissal", async () => {
    const user = userEvent.setup();
    render(<DesktopShellHeader {...actions()} />);
    await user.click(screen.getByRole("menuitem", { name: "Help" }));
    await user.click(screen.getByRole("menuitem", { name: "About K-Comms" }));
    expect(screen.getByRole("dialog", { name: "K-Comms" })).toHaveTextContent("conversations, calls and collaboration");
    await user.keyboard("{Escape}");
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
    await waitFor(() => expect(screen.getByRole("menuitem", { name: "Help" })).toHaveFocus());
  });

  it("lets Tab leave an open menu and continue into the workspace", async () => {
    const user = userEvent.setup();
    render(<><DesktopShellHeader {...actions()} /><input aria-label="Draft" /></>);
    await user.click(screen.getByRole("menuitem", { name: "File" }));
    await user.tab();
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    expect(screen.getByRole("textbox", { name: "Draft" })).toHaveFocus();
  });

  it("does not capture editor shortcuts or open over an existing consent dialog", async () => {
    const user = userEvent.setup();
    render(<><DesktopShellHeader {...actions()} /><input aria-label="Draft" /><section role="dialog" aria-modal="true">Consent</section></>);
    const field = screen.getByRole("textbox", { name: "Draft" });
    await user.click(field);
    await user.keyboard("draft{Control>}k{/Control}");
    expect(field).toHaveValue("draft");
    expect(field).toHaveFocus();
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("menuitem", { name: "File" }));
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  });

  it("keeps public actions accurate and omits navigation for an absent workspace", async () => {
    const user = userEvent.setup();
    const onOpenWorkspace = vi.fn();
    render(<DesktopShellHeader onNewInstantRoom={vi.fn()} onOpenWorkspace={onOpenWorkspace}
      workspaceMenuLabel="Open workspace" />);
    expect(screen.queryByRole("button", { name: "Toggle workspace navigation" })).not.toBeInTheDocument();
    await user.click(screen.getByRole("menuitem", { name: "File" }));
    await user.click(screen.getByRole("menuitem", { name: "Open workspace" }));
    expect(onOpenWorkspace).toHaveBeenCalledOnce();
    expect(screen.queryByRole("menuitem", { name: "View" })).not.toBeInTheDocument();
    expect(screen.queryByRole("menuitem", { name: "Search workspace…" })).not.toBeInTheDocument();
    expect(screen.queryByRole("menuitem", { name: "Keep navigation open" })).not.toBeInTheDocument();
  });
});

describe("DesktopShellHeader native boundary", () => {
  function nativeBridge() {
    let listener: ((action: NativeShellAction) => void) | undefined;
    const unsubscribe = vi.fn();
    const shell = {
      getState: vi.fn().mockResolvedValue({ version: 1, platform: "win32", nativeControls: true, nativeMenu: true }),
      showMenu: vi.fn().mockResolvedValue(undefined),
      subscribe: vi.fn((callback: (action: NativeShellAction) => void) => { listener = callback; return unsubscribe; }),
      setTheme: vi.fn().mockResolvedValue(undefined)
    };
    Object.defineProperty(window, "kCommsDesktop", { configurable: true, value: { version: 1, shell } });
    return { shell, unsubscribe, emit: (action: NativeShellAction) => listener?.(action) };
  }

  it("opens genuine fixed native menus and dispatches only valid intents outside dialogs", async () => {
    const user = userEvent.setup();
    const bridge = nativeBridge();
    const props = actions();
    const { rerender, unmount } = render(<DesktopShellHeader {...props} />);
    await user.click(await screen.findByRole("menuitem", { name: "Edit" }));
    expect(bridge.shell.showMenu).toHaveBeenCalledWith("edit");
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    act(() => bridge.emit("new-instant-room"));
    expect(props.onNewInstantRoom).toHaveBeenCalledOnce();
    act(() => bridge.emit("arbitrary-url" as NativeShellAction));
    expect(props.onOpenHelp).toBeUndefined();
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    rerender(<><DesktopShellHeader {...props} /><section role="dialog" aria-modal="true">Confirm capture</section></>);
    act(() => bridge.emit("new-instant-room"));
    expect(props.onNewInstantRoom).toHaveBeenCalledOnce();
    unmount();
    expect(bridge.unsubscribe).toHaveBeenCalledOnce();
    act(() => bridge.emit("new-instant-room"));
    expect(props.onNewInstantRoom).toHaveBeenCalledOnce();
  });

  it("honors explicit native search while editor shortcuts stay scoped to their owner", async () => {
    const user = userEvent.setup();
    const bridge = nativeBridge();
    const props = actions();
    const { rerender } = render(<><DesktopShellHeader {...props} /><textarea aria-label="Message draft" /><div contentEditable suppressContentEditableWarning tabIndex={0} aria-label="Document editor">Draft</div></>);
    await screen.findByRole("menuitem", { name: "Edit" });
    const field = screen.getByRole("textbox", { name: "Message draft" });
    await user.click(field);
    await user.keyboard("draft{Control>}k{/Control}");
    expect(props.onOpenSearch).not.toHaveBeenCalled();
    expect(field).toHaveValue("draft");
    expect(field).toHaveFocus();
    act(() => bridge.emit("open-search"));
    expect(props.onOpenSearch).toHaveBeenCalledOnce();
    expect(field).toHaveFocus();
    const editor = screen.getByLabelText("Document editor");
    editor.focus();
    act(() => bridge.emit("open-search"));
    expect(props.onOpenSearch).toHaveBeenCalledTimes(2);
    expect(editor).toHaveFocus();
    screen.getByRole("menuitem", { name: "View" }).focus();
    act(() => bridge.emit("open-search"));
    expect(props.onOpenSearch).toHaveBeenCalledTimes(3);
    rerender(<><DesktopShellHeader {...props} /><section role="dialog" aria-modal="true">Confirm capture</section></>);
    act(() => bridge.emit("open-search"));
    expect(props.onOpenSearch).toHaveBeenCalledTimes(3);
  });

  it("handles rejected native menus without adding fake controls", async () => {
    const user = userEvent.setup();
    const bridge = nativeBridge();
    bridge.shell.showMenu.mockRejectedValueOnce(new Error("Main frame not foreground"));
    render(<DesktopShellHeader {...actions()} />);
    await user.click(await screen.findByRole("menuitem", { name: "Edit" }));
    expect(await screen.findByRole("status")).toHaveTextContent("Desktop menu could not open");
    expect(screen.queryByRole("button", { name: /Close window/ })).not.toBeInTheDocument();
  });

  it("keeps native actions and About working while immersive chrome is absent", async () => {
    const user = userEvent.setup();
    const bridge = nativeBridge();
    const props = actions();
    const { unmount } = render(<DesktopShellHeader {...props} hideChrome />);
    await waitFor(() => expect(bridge.shell.subscribe).toHaveBeenCalledOnce());
    expect(screen.queryByRole("menubar")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Go back" })).not.toBeInTheDocument();
    act(() => bridge.emit("new-instant-room"));
    expect(props.onNewInstantRoom).toHaveBeenCalledOnce();
    act(() => bridge.emit("open-help"));
    expect(screen.getByRole("dialog", { name: "K-Comms" })).toHaveTextContent("Unsigned desktop evaluation");
    act(() => bridge.emit("new-instant-room"));
    expect(props.onNewInstantRoom).toHaveBeenCalledOnce();
    await user.keyboard("{Escape}");
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    act(() => bridge.emit("new-instant-room"));
    expect(props.onNewInstantRoom).toHaveBeenCalledTimes(2);
    unmount();
    expect(bridge.unsubscribe).toHaveBeenCalledOnce();
    act(() => bridge.emit("new-instant-room"));
    expect(props.onNewInstantRoom).toHaveBeenCalledTimes(2);
  });

  it("ignores late initialization after the owning header is unmounted", async () => {
    const bridge = nativeBridge();
    let resolve!: (value: unknown) => void;
    bridge.shell.getState.mockReturnValue(new Promise((done) => { resolve = done; }));
    const { unmount } = render(<DesktopShellHeader {...actions()} />);
    unmount();
    await act(async () => resolve({ version: 1, platform: "linux", nativeControls: true, nativeMenu: true }));
    expect(bridge.shell.subscribe).not.toHaveBeenCalled();
  });
});
