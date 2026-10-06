import { useState } from "react";
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { RealtimeInboxCallbacks } from "../realtime";
import type { Conversation, Session } from "../types";
import { WorkspaceDataProvider, useWorkspaceData } from "./workspace-data";

const harness = vi.hoisted(() => ({ session: null as Session | null, api: {
  conversations: vi.fn(), me: vi.fn(), users: vi.fn(), status: vi.fn(), socketTicket: vi.fn(), setConversationFavorite: vi.fn(), directConversation: vi.fn()
}, setSession: vi.fn(), inboxCallbacks: null as RealtimeInboxCallbacks | null }));
vi.mock("./session", () => ({ useSession: () => harness }));
vi.mock("../realtime", () => ({ socketEndpoint: () => "ws://fixture", RealtimeInbox: class {
  constructor(_endpoint: string, _ticket: string, _user: string, callbacks: RealtimeInboxCallbacks) { harness.inboxCallbacks = callbacks; }
  connect() {} disconnect() {}
} }));
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(done => { resolve = done; }); return { promise, resolve }; }
function Probe() {
  const data = useWorkspaceData();
  const [actionError, setActionError] = useState("");
  return <><pre data-testid="rows">{JSON.stringify(data.conversations)}</pre>
    <button onClick={() => void data.refreshConversations().catch(() => undefined)}>Refresh rows</button>
    <button onClick={() => void data.updateConversationFavorite("conversation", true)}>Favorite</button>
    <button onClick={() => void data.startDirectConversation("other").catch(reason => setActionError(reason.message))}>Open direct</button>
    <output>{actionError}</output></>;
}
const row: Conversation = { id: "conversation", tenant_id: "tenant", kind: "channel", title: "General", counterpart_user_id: null,
  counterpart_display_name: null, visibility: "tenant", latest_sequence: 1, inserted_at: "2026-10-06T10:00:00Z", updated_at: "2026-10-06T10:00:00Z", favorite: false,
  inbox: { message: { id: "message", sequence: 1, sender_user_id: "other", sender_display_name: "Member", status: "active", excerpt: "PRIVATE PREVIEW", inserted_at: "2026-10-06T10:00:00Z" }, draft: null } };
function view() { return <WorkspaceDataProvider><Probe /></WorkspaceDataProvider>; }
describe("Inbox snapshot authority", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    harness.inboxCallbacks = null;
    harness.session = { access_token: "token", refresh_token: "refresh", token_type: "Bearer", expires_in: 900,
      tenant: { id: "tenant", slug: "workspace", name: "Workspace", status: "active" },
      user: { id: "user", tenant_id: "tenant", display_name: "Person", role: "member", status: "active", account_type: "human", access_scope: "workspace" },
      device: { id: "device", user_id: "user", name: "Browser", platform: "web" } };
    harness.api.me.mockImplementation(async () => ({ ...harness.session, capabilities: {} }));
    harness.api.users.mockResolvedValue([]); harness.api.status.mockResolvedValue({ capabilities: {} });
    harness.api.socketTicket.mockResolvedValue({ ticket: "fixture" });
    harness.api.conversations.mockResolvedValue([row]);
    harness.api.setConversationFavorite.mockResolvedValue({ conversation_id: "conversation", favorite: true });
  });

  it("discards old previews immediately on same-user credential change and rejects its delayed read", async () => {
    const { rerender } = render(view());
    await waitFor(() => expect(screen.getByTestId("rows")).toHaveTextContent("PRIVATE PREVIEW"));
    const pending = deferred<Conversation[]>();
    harness.api.conversations.mockReturnValueOnce(pending.promise).mockResolvedValue([]);
    fireEvent.click(screen.getByRole("button", { name: "Refresh rows" }));
    harness.session = { ...harness.session!, access_token: "new-token" };
    rerender(view());
    expect(screen.getByTestId("rows")).not.toHaveTextContent("PRIVATE PREVIEW");
    await act(async () => pending.resolve([row]));
    expect(screen.getByTestId("rows")).not.toHaveTextContent("PRIVATE PREVIEW");
  });

  it("does not undo a successful favorite when an earlier list request finishes", async () => {
    render(view());
    await waitFor(() => expect(screen.getByTestId("rows")).toHaveTextContent('"favorite":false'));
    const pending = deferred<Conversation[]>(); harness.api.conversations.mockReturnValueOnce(pending.promise);
    fireEvent.click(screen.getByRole("button", { name: "Refresh rows" }));
    fireEvent.click(screen.getByRole("button", { name: "Favorite" }));
    await waitFor(() => expect(screen.getByTestId("rows")).toHaveTextContent('"favorite":true'));
    await act(async () => pending.resolve([row]));
    expect(screen.getByTestId("rows")).toHaveTextContent('"favorite":true');
  });

  it("clears excerpts after an unavailable or denied reload", async () => {
    render(view());
    await waitFor(() => expect(screen.getByTestId("rows")).toHaveTextContent("PRIVATE PREVIEW"));
    harness.api.conversations.mockRejectedValueOnce(new Error("forbidden"));
    fireEvent.click(screen.getByRole("button", { name: "Refresh rows" }));
    await waitFor(() => expect(screen.getByTestId("rows")).not.toHaveTextContent("PRIVATE PREVIEW"));
    expect(screen.getByTestId("rows")).toHaveTextContent("General");
  });
  it("preserves favorites, unread state and current preview when reopening a lean direct projection", async () => {
    harness.api.conversations.mockResolvedValue([{ ...row, kind: "direct", favorite: true, unread_count: 3, last_read_sequence: 0 }]);
    const metadata = { ...row };
    delete metadata.favorite; delete metadata.inbox;
    harness.api.directConversation.mockResolvedValue({ data: { ...metadata, kind: "direct", title: "Reopened direct" }, created: false });
    render(view());
    await waitFor(() => expect(screen.getByTestId("rows")).toHaveTextContent('"favorite":true'));
    fireEvent.click(screen.getByRole("button", { name: "Open direct" }));
    await waitFor(() => expect(screen.getByTestId("rows")).toHaveTextContent("Reopened direct"));
    expect(harness.api.directConversation).toHaveBeenCalledWith("other");
    expect(screen.getByTestId("rows")).toHaveTextContent('"favorite":true');
    expect(screen.getByTestId("rows")).toHaveTextContent('"unread_count":3');
    expect(screen.getByTestId("rows")).toHaveTextContent("PRIVATE PREVIEW");
  });

  it("drops the previous preview when direct admission reports a newer timeline", async () => {
    const metadata = { ...row };
    delete metadata.favorite; delete metadata.inbox;
    harness.api.directConversation.mockResolvedValue({ data: { ...metadata, latest_sequence: 2 }, created: false });
    render(view());
    await waitFor(() => expect(screen.getByTestId("rows")).toHaveTextContent("PRIVATE PREVIEW"));
    fireEvent.click(screen.getByRole("button", { name: "Open direct" }));
    await waitFor(() => expect(screen.getByTestId("rows")).not.toHaveTextContent("PRIVATE PREVIEW"));
  });

  it("cannot restore a removed conversation from a delayed direct-admission response", async () => {
    const pending = deferred<{ data: Conversation; created: boolean }>();
    harness.api.directConversation.mockReturnValue(pending.promise);
    render(view());
    await waitFor(() => expect(screen.getByTestId("rows")).toHaveTextContent("PRIVATE PREVIEW"));
    fireEvent.click(screen.getByRole("button", { name: "Open direct" }));
    await waitFor(() => expect(harness.inboxCallbacks).not.toBeNull());
    act(() => harness.inboxCallbacks!.onMembership({ conversation_id: row.id, action: "removed" }));
    await act(async () => pending.resolve({ data: row, created: false }));
    expect(screen.getByTestId("rows")).toHaveTextContent("[]");
    expect(screen.getByText("Conversation access changed. Try again.")).toBeVisible();
  });

});
