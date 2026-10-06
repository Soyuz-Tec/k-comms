import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useEffect, useState } from "react";
import { Link, MemoryRouter, Route, Routes } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import { routeLabel, RouteOrientation } from "./RouteOrientation";

function Harness() {
  return (
    <>
      <RouteOrientation />
      <nav>
        <Link to="/app/settings">Settings</Link>
        <Link to="/app/you#notification-settings">Notification preferences</Link>
      </nav>
      <Routes>
        <Route path="/app" element={<main id="main-content"><h1>Conversations</h1></main>} />
        <Route path="/app/settings" element={<main id="main-content"><h1>Profile and settings</h1></main>} />
        <Route path="/app/you" element={<DelayedNotificationSettings />} />
      </Routes>
    </>
  );
}

function DelayedNotificationSettings() {
  const [ready, setReady] = useState(false);
  useEffect(() => {
    const timer = window.setTimeout(() => setReady(true), 10);
    return () => window.clearTimeout(timer);
  }, []);
  return (
    <main id="main-content">
      <h1>Profile and settings</h1>
      {ready && <section id="notification-settings"><h2>Notification preferences</h2></section>}
    </main>
  );
}

describe("RouteOrientation", () => {
  afterEach(() => vi.restoreAllMocks());

  function deferFrames() {
    const frames = new Map<number, FrameRequestCallback>();
    let nextFrame = 0;
    vi.spyOn(window, "requestAnimationFrame").mockImplementation((callback) => {
      frames.set(++nextFrame, callback);
      return nextFrame;
    });
    vi.spyOn(window, "cancelAnimationFrame").mockImplementation((id) => { frames.delete(id); });
    return () => act(() => {
      for (const [id, callback] of [...frames]) {
        if (frames.delete(id)) callback(0);
      }
    });
  }

  it("does not steal newly selected account-summary focus while route orientation is pending", () => {
    const flushFrame = deferFrames();
    render(<MemoryRouter initialEntries={["/app/content"]}>
      <RouteOrientation />
      <details><summary>Account menu</summary><button>Set status</button></details>
      <main><h1>Content</h1></main>
    </MemoryRouter>);

    const summary = screen.getByText("Account menu");
    summary.focus();
    flushFrame();

    expect(summary).toHaveFocus();
    expect(screen.getByRole("heading", { name: "Content" })).not.toHaveAttribute("tabindex");
  });

  it.each(["keydown", "pointerdown"])("lets a subsequent %s operation cancel pending orientation without blocking normal navigation", (event) => {
    const flushFrame = deferFrames();
    render(<MemoryRouter initialEntries={["/app/"]}><Harness /></MemoryRouter>);
    flushFrame();
    const link = screen.getByRole("link", { name: "Settings" });
    link.focus();
    fireEvent.click(link);
    if (event === "keydown") fireEvent.keyDown(link, { key: "Tab" });
    else fireEvent.pointerDown(link);
    flushFrame();

    expect(link).toHaveFocus();
    expect(screen.getByRole("heading", { name: "Profile and settings" })).not.toHaveAttribute("tabindex");
  });

  it("stops waiting for a fragment when the user selects another control", async () => {
    const flushFrame = deferFrames();
    render(<MemoryRouter initialEntries={["/app/you#notification-settings"]}>
      <RouteOrientation />
      <details><summary>Account menu</summary><button>Set status</button></details>
      <DelayedNotificationSettings />
    </MemoryRouter>);
    flushFrame();
    const summary = screen.getByText("Account menu");
    summary.focus();
    await screen.findByRole("heading", { name: "Notification preferences" });

    expect(summary).toHaveFocus();
    expect(screen.getByRole("heading", { name: "Notification preferences" })).not.toHaveAttribute("tabindex");
  });

  it("keeps an already focused main input when orientation runs", () => {
    const flushFrame = deferFrames();
    render(<MemoryRouter initialEntries={["/app/content"]}>
      <RouteOrientation />
      <main><h1>Content</h1><input aria-label="Search content" autoFocus /></main>
    </MemoryRouter>);
    flushFrame();
    expect(screen.getByRole("textbox", { name: "Search content" })).toHaveFocus();
  });

  it("names content destinations and all administration deep links", () => {
    expect(routeLabel("/app/meetings", "")).toBe("Meetings");
    expect(routeLabel("/app/artifacts", "")).toBe("Recordings and transcripts");
    expect(routeLabel("/app/saved", "")).toBe("Saved items");
    expect(routeLabel("/admin", "?section=domains")).toBe("Domains · Workspace administration");
    expect(routeLabel("/admin", "?section=usage")).toBe("Usage · Workspace administration");
  });
  it("labels signed-out app routes as sign-in and prioritizes the task heading", async () => {
    render(
      <MemoryRouter initialEntries={["/admin?section=people"]}>
        <RouteOrientation authenticated={false} />
        <main>
          <h1>Marketing story</h1>
          <h2 data-route-focus>Sign in to your workspace</h2>
        </main>
      </MemoryRouter>
    );

    const signIn = screen.getByRole("heading", { name: "Sign in to your workspace" });
    await waitFor(() => expect(signIn).toHaveFocus());
    expect(document.title).toBe("Sign in | K-Comms");
    expect(screen.getByText("Sign in view")).toHaveAttribute("aria-live", "polite");
  });

  it("ignores an inert canvas main and focuses the visible authentication task", async () => {
    render(<MemoryRouter initialEntries={["/sign-in"]}>
      <RouteOrientation authenticated={false} />
      <div inert aria-hidden="true"><main><h1>Drawing canvas</h1></main></div>
      <section><h1 data-route-focus>Sign in to your workspace</h1></section>
    </MemoryRouter>);
    await waitFor(() => expect(screen.getByRole("heading", { name: "Sign in to your workspace" })).toHaveFocus());
    expect(screen.getByText("Drawing canvas")).not.toHaveAttribute("tabindex");
  });

  it("orients the guest entry as a join task instead of a sign-in task", async () => {
    render(
      <MemoryRouter initialEntries={["/join"]}>
        <RouteOrientation authenticated={false} />
        <main>
          <h1>Open a K-Comms guest link</h1>
        </main>
      </MemoryRouter>
    );

    const join = screen.getByRole("heading", { name: "Open a K-Comms guest link" });
    await waitFor(() => expect(join).toHaveFocus());
    expect(document.title).toBe("Join conversation | K-Comms");
    expect(screen.getByText("Join conversation view")).toHaveAttribute(
      "aria-live",
      "polite"
    );
  });

  it("orients the signed-out root as the instant-room task", async () => {
    render(
      <MemoryRouter initialEntries={["/"]}>
        <RouteOrientation authenticated={false} />
        <main>
          <h1>Start an instant room</h1>
        </main>
      </MemoryRouter>
    );

    const start = screen.getByRole("heading", { name: "Start an instant room" });
    await waitFor(() => expect(start).toHaveFocus());
    expect(document.title).toBe("Instant room | K-Comms");
    expect(screen.getByText("Instant room view")).toHaveAttribute(
      "aria-live",
      "polite"
    );
  });

  it("updates the document title and moves focus to the routed heading", async () => {
    const user = userEvent.setup();
    render(<MemoryRouter initialEntries={["/app/"]}><Harness /></MemoryRouter>);

    const conversations = screen.getByRole("heading", { name: "Conversations" });
    await waitFor(() => expect(conversations).toHaveFocus());
    expect(document.title).toBe("Inbox | K-Comms");

    await user.click(screen.getByRole("link", { name: "Settings" }));
    const settings = screen.getByRole("heading", { name: "Profile and settings" });
    await waitFor(() => expect(settings).toHaveFocus());
    expect(document.title).toBe("Profile and settings | K-Comms");
    expect(screen.getByText("Profile and settings view")).toHaveAttribute("aria-live", "polite");
  });

  it("waits for a fragment target, scrolls it into view, and focuses its heading", async () => {
    const user = userEvent.setup();
    const scrollIntoView = vi.spyOn(Element.prototype, "scrollIntoView");
    render(<MemoryRouter initialEntries={["/app/"]}><Harness /></MemoryRouter>);

    await user.click(screen.getByRole("link", { name: "Notification preferences" }));

    const destination = await screen.findByRole("heading", { name: "Notification preferences" });
    await waitFor(() => expect(destination).toHaveFocus());
    expect(scrollIntoView).toHaveBeenCalledWith({ block: "start" });
    scrollIntoView.mockRestore();
  });
});
