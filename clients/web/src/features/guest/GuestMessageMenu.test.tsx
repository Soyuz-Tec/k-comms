import { createRef } from "react";
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { GuestMessageMenu } from "./GuestMessageMenu";

describe("GuestMessageMenu", () => {
  it("contains only message actions and supports keyboard menu navigation", () => {
    const onClose = vi.fn();
    const onFocusComposer = vi.fn();
    const onJumpToLatest = vi.fn();
    const triggerRef = createRef<HTMLButtonElement>();

    render(
      <>
        <button ref={triggerRef} type="button">Message menu</button>
        <GuestMessageMenu
          onClose={onClose}
          onFocusComposer={onFocusComposer}
          onJumpToLatest={onJumpToLatest}
          triggerRef={triggerRef}
        />
      </>
    );

    const write = screen.getByRole("menuitem", { name: /Write a message/ });
    const latest = screen.getByRole("menuitem", { name: /Jump to latest/ });
    expect(write).toHaveFocus();
    expect(screen.queryByText(/Participants|Calls|Invite|Leave room/)).not
      .toBeInTheDocument();

    fireEvent.keyDown(write, { key: "ArrowDown" });
    expect(latest).toHaveFocus();
    fireEvent.keyDown(latest, { key: "Home" });
    expect(write).toHaveFocus();
    fireEvent.click(latest);
    expect(onClose).toHaveBeenCalledTimes(1);
    expect(onJumpToLatest).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole("menuitem", { name: /Collapse messages/ }))
      .not.toBeInTheDocument();
  });

  it("closes with Escape and restores focus to its integrated trigger", () => {
    const onClose = vi.fn();
    const triggerRef = createRef<HTMLButtonElement>();

    render(
      <>
        <button ref={triggerRef} type="button">Message menu</button>
        <GuestMessageMenu
          onClose={onClose}
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
