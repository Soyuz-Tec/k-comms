import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, useLocation } from "react-router";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createSharedDocumentsApi } from "../../api/domains/sharedDocuments";
import { ApiError } from "../../api/errors";
import type { SharedDocument } from "../../types/sharedDocuments";
import type * as DocumentHook from "./useSharedDocument";
import { optimisticApply } from "./documentModel";
import { DocumentsPage } from "./DocumentsPage";

// Exercise the real API serialization and maintained editor. Only server
// responses and the independently tested synchronization hook are controlled.
const harness = vi.hoisted(() => ({
  request: vi.fn(), api: { sharedDocuments: {} as ReturnType<typeof createSharedDocumentsApi>, socketTicket: vi.fn() },
  realHook: false, session: { access_token: "first-access", refresh_token: "first-refresh", received_at: 1, tenant: { id: "tenant", status: "active" }, user: { id: "user", tenant_id: "tenant", role: "owner", status: "active", version: 1, account_type: "human", access_scope: "workspace" }, device: { id: "device", user_id: "user", revoked_at: null as string | null } },
  epoch: 1, view: {} as ReturnType<typeof DocumentHook.useSharedDocument>
}));
vi.mock("../../app/session", () => ({ useSession: () => ({ api: harness.api, session: harness.session }) }));
vi.mock("../../app/workspace-data", () => ({ useWorkspaceData: () => ({ conversations: [{ id: "conversation", title: "Team" }], loading: false }) }));
vi.mock("./useSharedDocument", async importOriginal => {
  const actual = await importOriginal<typeof DocumentHook>();
  return { ...actual, useSharedDocument: (id: string) => harness.realHook ? actual.useSharedDocument(id) : harness.view };
});
vi.mock("./DocumentRealtime", () => ({ DocumentRealtime: class {
  connect = async () => undefined;
  disconnect = () => undefined;
  presence = () => undefined;
} }));
const document = (title = "Notes"): SharedDocument => ({ id: "doc", conversation_id: "conversation", title, content: "", atoms: [], generation: 1, version: 1, readonly: false, updated_at: "2026-10-05T00:00:00Z" });
function RouteLocation() { return <output aria-label="Document route">{useLocation().search}</output>; }
const page = () => <MemoryRouter initialEntries={["/app/documents?conversation=conversation&document=doc"]}><DocumentsPage /><RouteLocation /></MemoryRouter>;
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(done => { resolve = done; }); return { promise, resolve }; }
const actionCalls = () => harness.request.mock.calls.filter(([path]) => String(path).endsWith("/copies") || String(path).endsWith("/operations"));

beforeEach(() => {
  vi.resetAllMocks(); harness.epoch = 1; harness.realHook = false;
  harness.session = { access_token: "first-access", refresh_token: "first-refresh", received_at: 1, tenant: { id: "tenant", status: "active" }, user: { id: "user", tenant_id: "tenant", role: "owner", status: "active", version: 1, account_type: "human", access_scope: "workspace" }, device: { id: "device", user_id: "user", revoked_at: null } };
  harness.api.socketTicket.mockResolvedValue({ ticket: "current-ticket" });
  harness.api.sharedDocuments = createSharedDocumentsApi(harness.request);
  harness.view = { document: document(), edit: vi.fn(), presence: vi.fn(), peers: [], status: "live", error: null, pendingCount: 0, authorityEpoch: 1,
    isCurrentAuthority: epoch => epoch === harness.epoch && harness.view.document !== null,
    reportAuthorityFailure: failure => {
      if (![401, 403, 404].includes(Number((failure as { status?: unknown })?.status))) return false;
      harness.epoch++; harness.view = { ...harness.view, authorityEpoch: harness.epoch, document: null, status: "unavailable", error: "Your access changed" }; return true;
    }
  };
  harness.request.mockResolvedValue({ data: [] });
});

afterEach(() => vi.unstubAllGlobals());

describe("shared document library", () => {
  it("shows a readable excerpt and last update, then resumes the selected document", async () => {
    harness.request.mockResolvedValue({ data: [{ ...document("Launch notes"), excerpt: "Agenda and decisions from the launch review" }] });
    render(<MemoryRouter initialEntries={["/app/documents?conversation=conversation"]}><DocumentsPage /><RouteLocation /></MemoryRouter>);
    expect(await screen.findByRole("button", { name: /^Launch notes/ })).toHaveTextContent("Agenda and decisions from the launch review");
    expect(screen.getByText(/Updated/)).toHaveAttribute("datetime", "2026-10-05T00:00:00Z");
    expect(screen.getByRole("heading", { name: "Choose a document to continue" })).toBeVisible();
    fireEvent.click(screen.getByRole("button", { name: "Continue Launch notes" }));
    expect(screen.getByLabelText("Document route")).toHaveTextContent("conversation=conversation&document=doc");
    expect(screen.queryByRole("heading", { name: "Choose a document to continue" })).not.toBeInTheDocument();
  });
});

describe("immutable document command retries", () => {
  it("recovers a committed copy with the original UUID and scalar-safe title", async () => {
    harness.view.document = document("a".repeat(149) + "😀");
    let copies = 0;
    harness.request.mockImplementation(async path => {
      if (!String(path).endsWith("/copies")) return { data: [] };
      if (++copies === 1) throw new Error("Committed response lost");
      return { data: { ...document("Recovered copy"), id: "copy" } };
    });
    const { rerender } = render(page());
    fireEvent.click(screen.getByRole("button", { name: "Make a copy" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Retry the pending action");
    expect(screen.getByRole("button", { name: "Make a copy" })).toBeDisabled();
    const first = JSON.parse(actionCalls()[0]![1].body as string) as { title: string; client_document_id: string };
    expect(first.title).toBe("a".repeat(149) + "😀 copy");
    harness.view = { ...harness.view, document: { ...document("Peer changed the source title"), version: 2 } }; rerender(page());
    fireEvent.click(screen.getByRole("button", { name: "Retry pending action" }));
    await waitFor(() => expect(actionCalls()).toHaveLength(2));
    expect(actionCalls()[1]![1].body).toBe(actionCalls()[0]![1].body);
    await waitFor(() => expect(screen.queryByRole("button", { name: "Retry pending action" })).not.toBeInTheDocument());
    await waitFor(() => expect(screen.getByLabelText("Document route")).toHaveTextContent("document=copy"));
  });
  it("retries an uncertain rename with the original base version and title after a peer update", async () => {
    let renames = 0;
    harness.request.mockImplementation(async path => {
      if (!String(path).endsWith("/operations")) return { data: [] };
      if (++renames === 1) throw new Error("Response lost");
      return { data: {} };
    });
    const { rerender } = render(page());
    fireEvent.click(screen.getByRole("button", { name: "Rename" }));
    fireEvent.change(screen.getByLabelText("Document title"), { target: { value: "Original intent" } });
    fireEvent.click(screen.getByRole("button", { name: "Save title" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Retry the pending action");
    expect(screen.getByLabelText("Document title")).toBeDisabled();
    harness.view = { ...harness.view, document: { ...document("Peer rename"), version: 9 } }; rerender(page());
    fireEvent.click(screen.getByRole("button", { name: "Retry pending action" }));
    await waitFor(() => expect(actionCalls()).toHaveLength(2));
    expect(actionCalls()[1]![1].body).toBe(actionCalls()[0]![1].body);
    expect(JSON.parse(actionCalls()[1]![1].body as string)).toMatchObject({ title: "Original intent", generation: 1, base_version: 1 });
    await waitFor(() => expect(screen.queryByLabelText("Document title")).not.toBeInTheDocument());
  });
  it("clears the editor and pending title when an action definitively loses authority", async () => {
    harness.request.mockImplementation(async path => { if (String(path).endsWith("/copies")) throw new ApiError(403, "forbidden", "Withdrawn"); return { data: [] }; });
    render(page()); fireEvent.click(screen.getByRole("button", { name: "Make a copy" }));
    expect(await screen.findByRole("heading", { name: "Document unavailable" })).toBeVisible();
    expect(screen.queryByRole("button", { name: "Retry pending action" })).not.toBeInTheDocument();
    expect(window.document.querySelector(".cm-editor")).toBeNull();
  });
  it("clears cached private library titles and drafts when current membership is withdrawn", async () => {
    let withdrawn = false;
    harness.request.mockImplementation(async path => {
      if (String(path).endsWith("/copies")) { withdrawn = true; throw new ApiError(403, "forbidden", "Withdrawn"); }
      if (withdrawn) throw new ApiError(403, "forbidden", "Withdrawn");
      return { data: [{ ...document("Private library title"), excerpt: "Private excerpt" }] };
    });
    render(page()); await screen.findByRole("button", { name: /Private library title/ });
    fireEvent.change(screen.getByLabelText("New document title"), { target: { value: "Private draft" } });
    fireEvent.click(screen.getByRole("button", { name: "Make a copy" }));
    await screen.findByRole("heading", { name: "Document unavailable" });
    await waitFor(() => expect(screen.queryByRole("button", { name: /Private library title/ })).not.toBeInTheDocument());
    expect(screen.getByLabelText("New document title")).toHaveValue("");
  });
  it("ignores a delayed successful copy after the document authority epoch changes", async () => {
    const pending = deferred<{ data: SharedDocument }>();
    harness.request.mockImplementation(path => String(path).endsWith("/copies") ? pending.promise : Promise.resolve({ data: [] }));
    const { rerender } = render(page()); fireEvent.click(screen.getByRole("button", { name: "Make a copy" }));
    harness.epoch++; harness.view = { ...harness.view, authorityEpoch: harness.epoch, document: null, status: "unavailable" }; rerender(page());
    await act(async () => pending.resolve({ data: { ...document(), id: "copy" } }));
    expect(screen.getByRole("heading", { name: "Document unavailable" })).toBeVisible();
    expect(screen.queryByRole("heading", { name: "Notes" })).not.toBeInTheDocument();
    expect(screen.getByLabelText("Document route")).toHaveTextContent("document=doc");
  });
  it("does not reopen a delayed creation after the current document loses authority", async () => {
    const pending = deferred<{ data: SharedDocument }>();
    harness.request.mockImplementation(path => String(path) === "/api/v1/conversations/conversation/documents" ? pending.promise : Promise.resolve({ data: [] }));
    const { rerender } = render(page());
    fireEvent.change(screen.getByLabelText("New document title"), { target: { value: "New private document" } });
    await waitFor(() => expect(screen.getByRole("button", { name: "Create document" })).toBeEnabled());
    fireEvent.click(screen.getByRole("button", { name: "Create document" }));
    harness.epoch++; harness.view = { ...harness.view, authorityEpoch: harness.epoch, document: null, status: "unavailable" }; rerender(page());
    await act(async () => pending.resolve({ data: { ...document("New private document"), id: "created" } }));
    expect(screen.getByLabelText("Document route")).toHaveTextContent("document=doc");
    expect(screen.getByLabelText("New document title")).toHaveValue("");
  });
  it("ignores delayed export plaintext after authority withdrawal", async () => {
    const pending = deferred<{ data: SharedDocument }>();
    harness.request.mockImplementation(path => String(path) === "/api/v1/documents/doc" ? pending.promise : Promise.resolve({ data: [] }));
    const objectUrl = vi.fn(); vi.stubGlobal("URL", class extends URL { static createObjectURL = objectUrl; });
    const { rerender } = render(page()); fireEvent.click(screen.getByRole("button", { name: "Export text" }));
    harness.epoch++; harness.view = { ...harness.view, authorityEpoch: harness.epoch, document: null, status: "unavailable" }; rerender(page());
    await act(async () => pending.resolve({ data: { ...document(), content: "withdrawn secret" } }));
    expect(objectUrl).not.toHaveBeenCalled();
  });
  it.each(["access credential", "refresh credential", "role", "owner version"] as const)("drops old reads/copy/export on same-identity %s changes with the actual hook", async binding => {
    harness.realHook = true;
    const copied = deferred<{ data: SharedDocument }>(), exported = deferred<{ data: SharedDocument }>(), listed = deferred<{ data: SharedDocument[] }>();
    let changed = false, holdList = false, holdExport = false;
    const content = "Old private content", privateDocument = { ...document("Old private title"), content, atoms: optimisticApply([], {
      client_operation_id: "00000000-0000-4000-8000-000000000001", generation: 1, base_version: 1, kind: "edit", changes: [{ after_id: null, insert: content, delete_ids: [] }]
    }, 1) };
    harness.request.mockImplementation(async path => {
      if (String(path).endsWith("/copies")) return copied.promise;
      if (String(path) === "/api/v1/documents/doc" && holdExport) return exported.promise;
      if (String(path).includes("/documents?q=") && holdList) return listed.promise;
      if (changed) throw new ApiError(403, "forbidden", "Current scope denied");
      if (String(path) === "/api/v1/documents/doc") return { data: privateDocument };
      if (String(path).includes("/operations?")) return { data: [], page: { generation: 1, through_version: 1, next_after_version: 1, has_more: false } };
      return { data: [privateDocument] };
    });
    const objectUrl = vi.fn(); vi.stubGlobal("URL", class extends URL { static createObjectURL = objectUrl; });
    const { rerender } = render(page());
    await screen.findByRole("heading", { name: "Old private title" });
    await waitFor(() => expect(screen.getByRole("button", { name: "Make a copy" })).toBeEnabled());
    holdList = true; fireEvent.change(screen.getByRole("searchbox"), { target: { value: "private search" } });
    // Copy and export use the same current-authority fence, so qualify each
    // on different bindings while an old library read is also unresolved.
    if (binding === "role" || binding === "owner version") {
      holdExport = true; fireEvent.click(screen.getByRole("button", { name: "Export text" }));
    } else fireEvent.click(screen.getByRole("button", { name: "Make a copy" }));
    changed = true; holdList = false; holdExport = false;
    if (binding === "access credential") harness.session = { ...harness.session, access_token: "next-access" };
    if (binding === "refresh credential") harness.session = { ...harness.session, refresh_token: "next-refresh" };
    if (binding === "role") harness.session = { ...harness.session, user: { ...harness.session.user, role: "member" } };
    if (binding === "owner version") harness.session = { ...harness.session, user: { ...harness.session.user, version: 2 } };
    rerender(page()); await screen.findByRole("heading", { name: "Document unavailable" });
    await act(async () => { copied.resolve({ data: { ...privateDocument, id: "copy" } }); exported.resolve({ data: privateDocument }); listed.resolve({ data: [privateDocument] }); });
    expect(screen.getByLabelText("Document route")).toHaveTextContent("document=doc");
    expect(screen.queryByRole("heading", { name: "Old private title" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /Old private title/ })).not.toBeInTheDocument();
    expect(screen.getByRole("searchbox")).toHaveValue(""); expect(window.document.querySelector(".cm-editor")).toBeNull();
    expect(objectUrl).not.toHaveBeenCalled();
    expect(window.document.body.innerHTML).not.toContain(harness.session.access_token);
    expect(window.document.body.innerHTML).not.toContain(harness.session.refresh_token);
  });
  it("retains the original pending command on an innocuous equivalent session object", async () => {
    let copies = 0;
    harness.request.mockImplementation(async path => {
      if (!String(path).endsWith("/copies")) return { data: [] };
      if (++copies === 1) throw new Error("Committed response lost");
      return { data: { ...document(), id: "copy" } };
    });
    const { rerender } = render(page()); fireEvent.click(screen.getByRole("button", { name: "Make a copy" }));
    await screen.findByRole("button", { name: "Retry pending action" });
    harness.session = { ...structuredClone(harness.session), received_at: 2 }; rerender(page());
    fireEvent.click(screen.getByRole("button", { name: "Retry pending action" }));
    await waitFor(() => expect(screen.getByLabelText("Document route")).toHaveTextContent("document=copy"));
    expect(actionCalls()[1]![1].body).toBe(actionCalls()[0]![1].body);
  });

});
