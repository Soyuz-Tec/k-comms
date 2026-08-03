import { createRef } from "react";
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { GuestMessageMenu } from "./GuestMessageMenu";

describe("GuestMessageMenu", () => {
  it("contains only message actions and supports keyboard menu navigation", () => {
    const onClose = vi.fn();
    const onCollapse = vi.fn();
    const onFocusComposer = vi.fn();
    const onJumpToLatest = vi.fn();
    const triggerRef = createRef<HTMLButtonElement>();

    render(
      <>
        <button ref={triggerRef} type="button">Message menu</button>
        <GuestMessageMenu
          onClose={onClose}
          onCollapse={onCollapse}
          onFocusComposer={onFocusComposer}
          onJumpToLatest={onJumpToLatest}
          triggerRef={triggerRef}
        />
      </>
    );

    const write = screen.getByRole("menuitem", { name: /Write a message/ });
    const latest = screen.getByRole("menuitem", { name: /Jump to latest/ });
    const collapse = screen.getByRole("menuitem", { name: /Collapse messages/ });
    expect(write).toHaveFocus();
    expect(screen.queryByText(/Participants|Calls|Invite|Leave room/)).not
      .toBeInTheDocument();

    fireEvent.keyDown(write, { key: "ArrowDown" });
    expect(latest).toHaveFocus();
    fireEvent.keyDown(latest, { key: "End" });
    expect(collapse).toHaveFocus();
    fireEvent.click(collapse);
    expect(onClose).toHaveBeenCalledTimes(1);
    expect(onCollapse).toHaveBeenCalledTimes(1);
  });

  it("closes with Escape and restores focus to its integrated trigger", () => {
    const onClose = vi.fn();
    const triggerRef = createRef<HTMLButtonElement>();

    render(
      <>
        <button ref={triggerRef} type="button">Message menu</button>
        <GuestMessageMenu
          onClose={onClose}
          onCollapse={vi.fn()}
          onFocusComposer={vi.fn()}
          onJumpToLatest={vi.fn()}
          triggerRef={triggerRef}
        />
      </>
    );

    fireEvent.keyDown(
      screen.getByRole("menu", { name: "Message controls" }),
      { key: "Escape" }
    );
    expect(onClose).toHaveBeenCalledTimes(1);
    expect(triggerRef.current).toHaveFocus();
  });
});
