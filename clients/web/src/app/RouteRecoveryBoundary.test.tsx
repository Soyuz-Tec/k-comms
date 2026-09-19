import { lazy, Suspense, useEffect, useState } from "react";
import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { Link, MemoryRouter, Route, Routes } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import { RouteRecoveryBoundary } from "./RouteRecoveryBoundary";

describe("route recovery", () => {
  afterEach(() => vi.restoreAllMocks());

  it("contains render failures, focuses recovery and retries without remounting the surrounding owner", async () => {
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    const user = userEvent.setup();
    let fail = true;
    const unmounted = vi.fn();
    function Page() {
      if (fail) throw new Error("private implementation detail");
      return <h1>Recovered content</h1>;
    }
    function Owner() {
      const [joined, setJoined] = useState(false);
      useEffect(() => unmounted, []);
      return <><button onClick={() => setJoined(true)}>Join call</button>
        <p>{joined ? "Call remains joined" : "No call"}</p>
        <RouteRecoveryBoundary><Page /></RouteRecoveryBoundary></>;
    }
    render(<MemoryRouter><Owner /></MemoryRouter>);
    expect(screen.getByRole("heading", { name: "This page could not open" })).toHaveFocus();
    await user.click(screen.getByRole("button", { name: "Join call" }));
    expect(screen.queryByText("private implementation detail")).not.toBeInTheDocument();
    fail = false;
    await user.click(screen.getByRole("button", { name: "Try again" }));
    expect(screen.getByRole("heading", { name: "Recovered content" })).toBeVisible();
    expect(screen.getByText("Call remains joined")).toBeVisible();
    expect(unmounted).not.toHaveBeenCalled();
  });

  it("requires deliberate reload for a rejected route chunk and never loops automatically", async () => {
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    const reload = vi.fn();
    const load = vi.fn().mockRejectedValue(new TypeError("Failed to fetch dynamically imported module"));
    const Page = lazy(load);
    render(<MemoryRouter><RouteRecoveryBoundary reload={reload}><Suspense fallback="Loading"><Page /></Suspense></RouteRecoveryBoundary></MemoryRouter>);
    expect(await screen.findByRole("alert")).toHaveTextContent("application files could not load");
    expect(load).toHaveBeenCalledOnce();
    expect(reload).not.toHaveBeenCalled();
    expect(screen.queryByRole("button", { name: "Try again" })).not.toBeInTheDocument();
    await userEvent.setup().click(screen.getByRole("button", { name: "Reload K-Comms" }));
    expect(reload).toHaveBeenCalledOnce();
  });

  it("resets a failed route on navigation while healthy surrounding state persists", async () => {
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    const unmounted = vi.fn();
    function Failure(): never { throw new Error("route failed"); }
    function Owner() {
      useEffect(() => unmounted, []);
      return <><Link to="/app/">Navigate inbox</Link><RouteRecoveryBoundary><Routes>
        <Route path="/broken" element={<Failure />} />
        <Route path="/app/" element={<h1>Inbox content</h1>} />
      </Routes></RouteRecoveryBoundary></>;
    }
    render(<MemoryRouter initialEntries={["/broken"]}><Owner /></MemoryRouter>);
    await act(async () => { await userEvent.setup().click(screen.getByRole("link", { name: "Navigate inbox" })); });
    await waitFor(() => expect(screen.getByRole("heading", { name: "Inbox content" })).toBeVisible());
    expect(unmounted).not.toHaveBeenCalled();
  });
});
