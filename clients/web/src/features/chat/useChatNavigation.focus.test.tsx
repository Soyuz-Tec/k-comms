import { useState } from "react";
import { act, fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, useSearchParams } from "react-router";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Conversation } from "../../types";
import { useChatNavigation } from "./useChatNavigation";
import { RouteOrientation } from "../../app/RouteOrientation";

const rows = [{ id: "general" }, { id: "direct" }] as Conversation[];
function Harness() {
  const [params, setSearchParams] = useSearchParams();
  const [body, setBody] = useState("");
  const navigation = useChatNavigation({ requestedConversationId: params.get("conversation"),
    conversations: rows, setSearchParams, workspaceLoading: false, closeConversationPanels: () => {} });
  return <main>
    <h1>Inbox</h1>
    <input aria-label="Filter conversations" />
    <button onClick={() => { navigation.focusComposerAfterDirect(); navigation.selectConversation("direct"); }}>Open direct</button>
    {navigation.mobilePane === "list" ? rows.map(row => <button key={row.id}
      ref={node => { if (node) navigation.conversationButtonRefs.current.set(row.id, node); else navigation.conversationButtonRefs.current.delete(row.id); }}
      onClick={() => navigation.selectConversation(row.id)}>{row.id}</button>) : <>
      <h2 data-route-focus>Conversation</h2>
      <button ref={navigation.mobileBackRef} onClick={navigation.showConversationList}>Back to conversations</button>
      <textarea id="message-composer" aria-label="Message" value={body} onChange={event => setBody(event.target.value)} />
    </>}
  </main>;
}

function deferFrames() {
  const frames = new Map<number, FrameRequestCallback>();
  let next = 0;
  vi.spyOn(window, "requestAnimationFrame").mockImplementation(callback => { frames.set(++next, callback); return next; });
  vi.spyOn(window, "cancelAnimationFrame").mockImplementation(id => { frames.delete(id); });
  return { count: () => frames.size, flush: () => act(() => {
    for (const [id, callback] of [...frames]) if (frames.delete(id)) callback(0);
  }) };
}

describe("conversation navigation focus ownership", () => {
  beforeEach(() => {
    vi.stubGlobal("matchMedia", vi.fn().mockImplementation((media: string) => ({
      matches: media === "(max-width: 760px)", media, addEventListener: vi.fn(), removeEventListener: vi.fn()
    })));
  });
  afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); });

  it("keeps ordinary mobile entry focused on Back", () => {
    const frames = deferFrames();
    render(<MemoryRouter initialEntries={["/app/?conversation=general"]}><Harness /></MemoryRouter>);
    frames.flush();
    expect(screen.getByRole("button", { name: "Back to conversations" })).toHaveFocus();
  });

  it("cannot steal composer focus after typing starts before the scheduled Back frame", () => {
    const frames = deferFrames();
    render(<MemoryRouter initialEntries={["/app/?conversation=general"]}><Harness /></MemoryRouter>);
    const composer = screen.getByRole("textbox", { name: "Message" });
    composer.focus();
    fireEvent.change(composer, { target: { value: "Started draft" } });
    frames.flush();
    expect(composer).toHaveFocus();
    expect(composer).toHaveValue("Started draft");
  });

  it.each(["keydown", "pointerdown"])("respects a later %s while mobile entry focus is pending", event => {
    const frames = deferFrames();
    render(<MemoryRouter initialEntries={["/app/?conversation=general"]}><Harness /></MemoryRouter>);
    const composer = screen.getByRole("textbox", { name: "Message" });
    if (event === "keydown") fireEvent.keyDown(composer, { key: "Tab" });
    else fireEvent.pointerDown(composer);
    frames.flush();
    expect(screen.getByRole("button", { name: "Back to conversations" })).not.toHaveFocus();
  });

  it("restores the selected row when returning to the mobile list", () => {
    const frames = deferFrames();
    render(<MemoryRouter initialEntries={["/app/?conversation=general"]}><Harness /></MemoryRouter>);
    frames.flush();
    fireEvent.click(screen.getByRole("button", { name: "Back to conversations" }));
    frames.flush();
    expect(screen.getByRole("button", { name: /^general$/ })).toHaveFocus();
  });

  it("keeps a newly selected list filter focused while row restoration is pending", () => {
    const frames = deferFrames();
    render(<MemoryRouter initialEntries={["/app/?conversation=general"]}><Harness /></MemoryRouter>);
    frames.flush();
    fireEvent.click(screen.getByRole("button", { name: "Back to conversations" }));
    const filter = screen.getByRole("textbox", { name: "Filter conversations" });
    filter.focus();
    frames.flush();
    expect(filter).toHaveFocus();
  });

  it("preserves explicit direct-conversation composer focus over ordinary Back focus", () => {
    const frames = deferFrames();
    render(<MemoryRouter initialEntries={["/app/"]}><Harness /></MemoryRouter>);
    fireEvent.click(screen.getByRole("button", { name: "Open direct" }));
    frames.flush();
    expect(screen.getByRole("textbox", { name: "Message" })).toHaveFocus();
  });

  it("does not steal newer user focus for a pending direct-conversation composer", () => {
    const frames = deferFrames();
    render(<MemoryRouter initialEntries={["/app/"]}><Harness /></MemoryRouter>);
    fireEvent.click(screen.getByRole("button", { name: "Open direct" }));
    const filter = screen.getByRole("textbox", { name: "Filter conversations" });
    filter.focus();
    frames.flush();
    expect(filter).toHaveFocus();
  });

  it("cancels queued focus when the conversation view unmounts", () => {
    const frames = deferFrames();
    const view = render(<MemoryRouter initialEntries={["/app/?conversation=general"]}><Harness /></MemoryRouter>);
    expect(frames.count()).toBeGreaterThan(0);
    view.unmount();
    expect(frames.count()).toBe(0);
    frames.flush();
  });

  it("keeps Back and list restoration ahead of generic route orientation", () => {
    const frames = deferFrames();
    render(<MemoryRouter initialEntries={["/app/?conversation=general"]}><RouteOrientation /><Harness /></MemoryRouter>);
    frames.flush();
    expect(screen.getByRole("button", { name: "Back to conversations" })).toHaveFocus();
    fireEvent.click(screen.getByRole("button", { name: "Back to conversations" }));
    frames.flush();
    expect(screen.getByRole("button", { name: /^general$/ })).toHaveFocus();
  });

  it("keeps explicit direct-composer focus ahead of generic route orientation", () => {
    const frames = deferFrames();
    render(<MemoryRouter initialEntries={["/app/"]}><RouteOrientation /><Harness /></MemoryRouter>);
    frames.flush();
    fireEvent.click(screen.getByRole("button", { name: "Open direct" }));
    frames.flush();
    expect(screen.getByRole("textbox", { name: "Message" })).toHaveFocus();
  });

  it("consumes canceled direct focus before later unrelated conversation navigation", () => {
    const frames = deferFrames();
    render(<MemoryRouter initialEntries={["/app/"]}><RouteOrientation /><Harness /></MemoryRouter>);
    frames.flush();
    fireEvent.click(screen.getByRole("button", { name: "Open direct" }));
    screen.getByRole("textbox", { name: "Filter conversations" }).focus();
    frames.flush();
    fireEvent.click(screen.getByRole("button", { name: "Back to conversations" }));
    frames.flush();
    fireEvent.click(screen.getByRole("button", { name: /^general$/ }));
    frames.flush();
    expect(screen.getByRole("button", { name: "Back to conversations" })).toHaveFocus();
  });
});
