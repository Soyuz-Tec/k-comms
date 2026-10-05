import { act, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "../../api/errors";
import type { DocumentEdit, DocumentOperation, DocumentReplay, SharedDocument } from "../../types/sharedDocuments";
import { optimisticApply } from "./documentModel";
import { useSharedDocument } from "./useSharedDocument";

const harness = vi.hoisted(() => ({
  api: { sharedDocuments: { get: vi.fn(), replay: vi.fn(), apply: vi.fn() }, socketTicket: vi.fn() },
  session: { access_token: "first-access", refresh_token: "first-refresh", received_at: 1, user: { id: "user", tenant_id: "tenant", role: "owner", status: "active", version: 1, account_type: "human", access_scope: "workspace" }, device: { id: "device", user_id: "user", revoked_at: null as string | null }, tenant: { id: "tenant", status: "active" } },
  sockets: [] as Array<{ operation: (operation: DocumentOperation) => void; presence: (presence: { user_id: string; device_id: string; generation: number; anchor_id: null; head_id: null }) => void; closed: () => void }>
}));
vi.mock("../../app/session", () => ({ useSession: () => harness }));
vi.mock("./DocumentRealtime", () => ({ DocumentRealtime: class {
  constructor(_endpoint: string, _ticket: string, _id: string, callbacks: (typeof harness.sockets)[number]) { harness.sockets.push(callbacks); }
  connect = async () => undefined;
  disconnect = () => undefined;
  presence = () => undefined;
} }));
const snapshot = (id = "doc"): SharedDocument => ({ id, conversation_id: "conversation", title: "Private notes", content: "", atoms: [], generation: 1, version: 1, readonly: false, updated_at: "2026-10-05T00:00:00Z" });
const replay: DocumentReplay = { data: [], page: { generation: 1, through_version: 1, next_after_version: 1, has_more: false } };
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(done => { resolve = done; }); return { promise, resolve }; }
function receipt(input: DocumentEdit): DocumentOperation { return { document_id: "doc", conversation_id: "conversation", generation: 1, version: 2, kind: "edit", title: null,
  client_operation_id: input.client_operation_id, inserted_atoms: optimisticApply([], input, 2), deleted_atom_ids: [], inserted_at: "2026-10-05T00:00:01Z" }; }
async function flush() { await act(async () => { await Promise.resolve(); }); }

describe("document outbox authority and scope", () => {
  beforeEach(() => {
    vi.useFakeTimers(); vi.resetAllMocks(); harness.sockets.length = 0;
    harness.session = { access_token: "first-access", refresh_token: "first-refresh", received_at: 1, user: { id: "user", tenant_id: "tenant", role: "owner", status: "active", version: 1, account_type: "human", access_scope: "workspace" }, device: { id: "device", user_id: "user", revoked_at: null }, tenant: { id: "tenant", status: "active" } };
    harness.api.sharedDocuments.get.mockResolvedValue(snapshot());
    harness.api.sharedDocuments.replay.mockResolvedValue(replay);
    harness.api.socketTicket.mockResolvedValue({ ticket: "current-ticket" });
  });
  afterEach(() => vi.useRealTimers());
  it.each([409, 422])("continues authority polling after edit rejection %s and clears withdrawn plaintext/outbox", async rejection => {
    harness.api.sharedDocuments.apply.mockRejectedValue(new ApiError(rejection, "capacity", "Rejected"));
    const { result } = renderHook(() => useSharedDocument("doc")); await flush();
    expect(result.current.status).toBe("live");
    act(() => {
      harness.sockets[0]!.presence({ user_id: "peer", device_id: "peer-device", generation: 1, anchor_id: null, head_id: null });
      result.current.edit([{ from: 0, to: 0, insert: "unsent private text" }]);
    }); await flush();
    expect(result.current.status).toBe("offline"); expect(result.current.pendingCount).toBe(1);
    expect(result.current.document?.content).toBe("unsent private text"); expect(result.current.peers).toHaveLength(1);
    harness.api.sharedDocuments.replay.mockRejectedValue(new ApiError(403, "forbidden", "Membership withdrawn"));
    await act(async () => { await vi.advanceTimersByTimeAsync(15_000); });
    expect(result.current.status).toBe("unavailable"); expect(result.current.document).toBeNull();
    expect(result.current.pendingCount).toBe(0); expect(result.current.peers).toEqual([]);
    expect(harness.api.sharedDocuments.apply).toHaveBeenCalledTimes(1);
  });
  it("does not resend a rejected edit when the transport reconnects but still checks authority", async () => {
    harness.api.sharedDocuments.apply.mockRejectedValue(new ApiError(409, "capacity", "Rejected"));
    const { result } = renderHook(() => useSharedDocument("doc")); await flush();
    act(() => result.current.edit([{ from: 0, to: 0, insert: "retained" }])); await flush();
    act(() => harness.sockets[0]!.closed());
    await act(async () => { await vi.advanceTimersByTimeAsync(3_000); });
    expect(result.current.status).toBe("offline"); expect(result.current.pendingCount).toBe(1);
    expect(harness.api.sharedDocuments.apply).toHaveBeenCalledTimes(1);
    const prior = harness.api.sharedDocuments.replay.mock.calls.length;
    await act(async () => { await vi.advanceTimersByTimeAsync(12_000); });
    expect(harness.api.sharedDocuments.replay.mock.calls.length).toBeGreaterThan(prior);
  });
  it("erases delayed replay/edit completions after a definitive action denial", async () => {
    const write = deferred<DocumentOperation>(), read = deferred<typeof replay>();
    harness.api.sharedDocuments.apply.mockReturnValue(write.promise);
    const { result } = renderHook(() => useSharedDocument("doc")); await flush();
    act(() => result.current.edit([{ from: 0, to: 0, insert: "secret" }]));
    const input = harness.api.sharedDocuments.apply.mock.calls[0]![1] as DocumentEdit;
    harness.api.sharedDocuments.replay.mockReturnValueOnce(read.promise);
    await act(async () => { await vi.advanceTimersByTimeAsync(15_000); });
    const epoch = result.current.authorityEpoch;
    act(() => { expect(result.current.reportAuthorityFailure(new ApiError(404, "not_found", "Erased"))).toBe(true); });
    expect(result.current.isCurrentAuthority(epoch)).toBe(false);
    await act(async () => { read.resolve(replay); write.resolve(receipt(input)); });
    expect(result.current.document).toBeNull(); expect(result.current.pendingCount).toBe(0);
    expect(result.current.status).toBe("unavailable");
    act(() => harness.sockets[0]!.operation(receipt(input))); await flush();
    expect(result.current.document).toBeNull();
  });
  it("preserves the exact unknown-ack edit through replay and retry without duplicating its text", async () => {
    harness.api.sharedDocuments.apply.mockRejectedValueOnce(new Error("Response lost"));
    const { result } = renderHook(() => useSharedDocument("doc")); await flush();
    act(() => result.current.edit([{ from: 0, to: 0, insert: "once" }])); await flush();
    const input = harness.api.sharedDocuments.apply.mock.calls[0]![1] as DocumentEdit;
    const committed = receipt(input);
    harness.api.sharedDocuments.replay.mockResolvedValue({ ...replay, data: [committed] });
    harness.api.sharedDocuments.apply.mockResolvedValue(committed);
    await act(async () => { await vi.advanceTimersByTimeAsync(3_000); });
    expect(harness.api.sharedDocuments.apply.mock.calls[1]![1]).toBe(input);
    expect(result.current.document?.content).toBe("once"); expect(result.current.pendingCount).toBe(0);
  });
  it("rejects a delayed snapshot from a previous identity and document epoch", async () => {
    const previous = deferred<SharedDocument>(); harness.api.sharedDocuments.get.mockReturnValueOnce(previous.promise).mockResolvedValueOnce(snapshot("new-doc"));
    const { result, rerender } = renderHook(({ id }) => useSharedDocument(id), { initialProps: { id: "old-doc" } });
    harness.session = { ...harness.session, user: { ...harness.session.user, id: "new-user" } }; rerender({ id: "new-doc" }); await flush();
    expect(result.current.document?.id).toBe("new-doc");
    await act(async () => previous.resolve({ ...snapshot("old-doc"), content: "old secret" }));
    expect(result.current.document?.id).toBe("new-doc"); expect(result.current.document?.content).toBe("");
  });
  it("treats a changed replay generation as terminal and clears local text", async () => {
    const { result } = renderHook(() => useSharedDocument("doc")); await flush();
    harness.api.sharedDocuments.replay.mockResolvedValue({ ...replay, page: { ...replay.page, generation: 2 } });
    await act(async () => { await vi.advanceTimersByTimeAsync(15_000); });
    expect(result.current.document).toBeNull(); expect(result.current.status).toBe("unavailable");
  });
  it.each(["access credential", "refresh credential", "role", "owner version", "status", "account type", "access scope", "device revocation", "tenant status"] as const)("fences same-identity %s changes while replay and edit receipts are pending", async binding => {
    const write = deferred<DocumentOperation>(), read = deferred<typeof replay>();
    harness.api.sharedDocuments.apply.mockReturnValue(write.promise);
    const { result, rerender } = renderHook(() => useSharedDocument("doc")); await flush();
    act(() => {
      harness.sockets[0]!.presence({ user_id: "peer", device_id: "peer-device", generation: 1, anchor_id: null, head_id: null });
      result.current.edit([{ from: 0, to: 0, insert: "old-scope secret" }]);
    });
    const input = harness.api.sharedDocuments.apply.mock.calls[0]![1] as DocumentEdit, oldEpoch = result.current.authorityEpoch;
    harness.api.sharedDocuments.replay.mockReturnValueOnce(read.promise);
    await act(async () => { await vi.advanceTimersByTimeAsync(15_000); });
    if (binding === "access credential") harness.session = { ...harness.session, access_token: "next-access" };
    if (binding === "refresh credential") harness.session = { ...harness.session, refresh_token: "next-refresh" };
    if (binding === "role") harness.session = { ...harness.session, user: { ...harness.session.user, role: "member" } };
    if (binding === "owner version") harness.session = { ...harness.session, user: { ...harness.session.user, version: 2 } };
    if (binding === "status") harness.session = { ...harness.session, user: { ...harness.session.user, status: "suspended" } };
    if (binding === "account type") harness.session = { ...harness.session, user: { ...harness.session.user, account_type: "service" } };
    if (binding === "access scope") harness.session = { ...harness.session, user: { ...harness.session.user, access_scope: "conversation_only" } };
    if (binding === "device revocation") harness.session = { ...harness.session, device: { ...harness.session.device, revoked_at: "2026-10-05T01:00:00Z" } };
    if (binding === "tenant status") harness.session = { ...harness.session, tenant: { ...harness.session.tenant, status: "suspended" } };
    harness.api.sharedDocuments.get.mockRejectedValueOnce(new ApiError(403, "forbidden", "Current scope denied"));
    rerender(); await flush();
    expect(result.current.document).toBeNull(); expect(result.current.pendingCount).toBe(0); expect(result.current.peers).toEqual([]);
    expect(result.current.isCurrentAuthority(oldEpoch)).toBe(false);
    expect(harness.api.sharedDocuments.get).toHaveBeenCalledTimes(2);
    await act(async () => { read.resolve({ ...replay, data: [receipt(input)] }); write.resolve(receipt(input)); });
    act(() => harness.sockets[0]!.operation(receipt(input))); await flush();
    expect(result.current.document).toBeNull(); expect(result.current.pendingCount).toBe(0);
    expect(harness.api.sharedDocuments.apply).toHaveBeenCalledTimes(1);
  });
  it("ignores an old same-identity snapshot after credentials rotate", async () => {
    const previous = deferred<SharedDocument>();
    harness.api.sharedDocuments.get.mockReturnValueOnce(previous.promise).mockRejectedValueOnce(new ApiError(403, "forbidden", "Current scope denied"));
    const { result, rerender } = renderHook(() => useSharedDocument("doc"));
    harness.session = { ...harness.session, access_token: "next-access" }; rerender(); await flush();
    await act(async () => previous.resolve({ ...snapshot(), title: "Old private title", content: "old private text" }));
    expect(result.current.document).toBeNull(); expect(result.current.status).toBe("unavailable");
  });
  it("preserves an outbox and authority epoch for equivalent session objects and timing metadata", async () => {
    const write = deferred<DocumentOperation>(); harness.api.sharedDocuments.apply.mockReturnValue(write.promise);
    const { result, rerender } = renderHook(() => useSharedDocument("doc")); await flush();
    act(() => result.current.edit([{ from: 0, to: 0, insert: "retain intent" }]));
    const epoch = result.current.authorityEpoch;
    harness.session = { ...structuredClone(harness.session), received_at: 2 }; rerender(); await flush();
    expect(result.current.authorityEpoch).toBe(epoch); expect(result.current.pendingCount).toBe(1);
    expect(result.current.document?.content).toBe("retain intent"); expect(harness.api.sharedDocuments.get).toHaveBeenCalledTimes(1);
  });

});
