import { useEffect } from "react";
import { act, render, screen } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { DesktopBoundary } from "./DesktopBoundary";

afterEach(() => { Reflect.deleteProperty(window, "kCommsDesktop"); });
it("shows honest unsigned limitations and unmounts active UI cleanup on native storage failure", async () => {
  Object.defineProperty(window, "kCommsDesktop", { configurable: true, value: { version: 1 } });
  const stopOwnedSocketAndMedia = vi.fn();
  function ActiveUi() { useEffect(() => stopOwnedSocketAndMedia, []); return <p>Active workspace</p>; }
  render(<DesktopBoundary><ActiveUi /></DesktopBoundary>);
  expect(screen.getByRole("status").textContent).toContain("Automatic updates are off");
  expect(screen.getByRole("status").textContent).toContain("qualification is pending");
  await act(async () => { window.dispatchEvent(new Event("k-comms:desktop-storage-failed")); });
  expect(screen.queryByText("Active workspace")).not.toBeInTheDocument(); expect(stopOwnedSocketAndMedia).toHaveBeenCalledOnce(); expect(screen.getByRole("alert")).toHaveTextContent("Saved access must be confirmed");
});
it("keeps the existing browser UI free of desktop evaluation notices", () => {
  render(<DesktopBoundary><p>Browser workspace</p></DesktopBoundary>); expect(screen.getByText("Browser workspace")).toBeInTheDocument(); expect(screen.queryByRole("status")).not.toBeInTheDocument();
});
