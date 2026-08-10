import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  CALL_TERMINAL_NOTICE_TIMEOUT_MS,
  CallTerminalNotice
} from "./CallPanel";

describe("CallTerminalNotice", () => {
  afterEach(() => vi.useRealTimers());

  it("can be dismissed immediately", () => {
    const onDismiss = vi.fn();
    render(
      <CallTerminalNotice
        title="Audio call ended"
        message="The audio call was ended for everyone."
        onDismiss={onDismiss}
      />
    );

    fireEvent.click(screen.getByRole("button", { name: "Dismiss call notice" }));
    expect(onDismiss).toHaveBeenCalledOnce();
  });

  it("automatically dismisses an informational ended notice", () => {
    vi.useFakeTimers();
    const onDismiss = vi.fn();
    render(
      <CallTerminalNotice
        title="Audio call ended"
        message="The audio call was ended for everyone."
        autoDismiss
        onDismiss={onDismiss}
      />
    );

    act(() => vi.advanceTimersByTime(CALL_TERMINAL_NOTICE_TIMEOUT_MS - 1));
    expect(onDismiss).not.toHaveBeenCalled();
    act(() => vi.advanceTimersByTime(1));
    expect(onDismiss).toHaveBeenCalledOnce();
  });

  it("keeps a critical notice until the person dismisses it", () => {
    vi.useFakeTimers();
    const onDismiss = vi.fn();
    render(
      <CallTerminalNotice
        title="Audio access revoked"
        message="Sign in again or contact an administrator."
        error
        onDismiss={onDismiss}
      />
    );

    act(() => vi.advanceTimersByTime(CALL_TERMINAL_NOTICE_TIMEOUT_MS * 2));
    expect(onDismiss).not.toHaveBeenCalled();
    expect(screen.getByRole("alert")).toBeVisible();
  });
});
