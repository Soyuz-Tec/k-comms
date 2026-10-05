import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiClient } from "../../api";
import type { Session } from "../../types";
import { historyPage } from "../../features/admin/deletionTimeline.testSupport";

const session: Session = {
  access_token: "synthetic-access-token", refresh_token: "synthetic-refresh-token", token_type: "Bearer", expires_in: 900,
  tenant: { id: "synthetic-tenant", name: "Synthetic workspace", slug: "synthetic", status: "active" },
  user: { id: "synthetic-owner", tenant_id: "synthetic-tenant", display_name: "Reviewer", role: "owner", status: "active" },
  device: { id: "synthetic-device", user_id: "synthetic-owner", name: "Browser", platform: "web" }
};
function exportResponse(headers: Record<string, string> = {}) {
  return new Response("action,status\r\nrequested,pending\r\n", { headers: {
    "content-type": "text/csv", "content-disposition": 'attachment; filename="deletion-request-history.csv"',
    "x-export-row-count": "1", "x-export-truncated": "false", "x-export-maximum-rows": "5000",
    "x-history-snapshot": "synthetic-snapshot", "x-history-coverage": "partial", "x-history-retained-only": "true",
    "x-history-observed-at": "2026-10-05T00:03:00Z", ...headers
  } });
}
const invalidReceipts: Record<string, string>[] = [
  { "x-history-snapshot": "different-snapshot" }, { "x-history-retained-only": "false" },
  { "x-export-row-count": "not-a-count" }, { "x-history-observed-at": "not-a-time" }
];
afterEach(() => { vi.unstubAllGlobals(); vi.useRealTimers(); });

describe("governance history transport", () => {
  it("unwraps the page and sends cursor-only continuation without changing immutable limits", async () => {
    const fetchMock = vi.fn<typeof fetch>().mockImplementation(async () => new Response(JSON.stringify({ data: historyPage() }), { headers: { "content-type": "application/json" } }));
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://synthetic.example.test", session, vi.fn());
    await expect(api.deletionHistory("request/one", { limit: 25 })).resolves.toEqual(historyPage());
    await api.deletionHistory("request/one", { cursor: "opaque/next?token" });
    expect(fetchMock.mock.calls.map(([url]) => String(url))).toEqual([
      "https://synthetic.example.test/api/v1/admin/deletion-requests/request%2Fone/timeline?limit=25",
      "https://synthetic.example.test/api/v1/admin/deletion-requests/request%2Fone/timeline?cursor=opaque%2Fnext%3Ftoken"
    ]);
  });

  it("uses GET for the exact snapshot CSV and preserves exposed coverage receipt metadata", async () => {
    const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(exportResponse());
    vi.stubGlobal("fetch", fetchMock);
    const file = await new ApiClient("https://synthetic.example.test", session, vi.fn()).exportDeletionHistory("deletion-1", "synthetic-snapshot");
    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://synthetic.example.test/api/v1/admin/deletion-requests/deletion-1/timeline/export?snapshot=synthetic-snapshot&limit=5000");
    expect(fetchMock.mock.calls[0]?.[1]?.method).toBeUndefined();
    expect(new Headers(fetchMock.mock.calls[0]?.[1]?.headers).get("Accept")).toBe("text/csv");
    expect(file).toMatchObject({ count: 1, truncated: false, filename: "deletion-request-history.csv", history: {
      snapshot: "synthetic-snapshot", coverage: "partial", maximumRows: 5000, retainedOnly: true, observedAt: "2026-10-05T00:03:00Z"
    } });
    expect(await file.blob.text()).toContain("requested,pending");
  });

  it.each(invalidReceipts)("rejects an unverified snapshot CSV receipt: %j", async (headers) => {
    vi.stubGlobal("fetch", vi.fn<typeof fetch>().mockResolvedValue(exportResponse(headers)));
    await expect(new ApiClient("https://synthetic.example.test", session, vi.fn()).exportDeletionHistory("deletion-1", "synthetic-snapshot"))
      .rejects.toMatchObject({ code: "invalid_history_export" });
  });

  it("discards an export that completes after the initiating account changes", async () => {
    let finish!: (response: Response) => void;
    vi.stubGlobal("fetch", vi.fn<typeof fetch>().mockReturnValue(new Promise<Response>((resolve) => { finish = resolve; })));
    const api = new ApiClient("https://synthetic.example.test", session, vi.fn());
    const pending = api.exportDeletionHistory("deletion-1", "synthetic-snapshot");
    const rejected = expect(pending).rejects.toMatchObject({ code: "session_changed" });
    api.setSession({ ...session, user: { ...session.user, id: "another-synthetic-owner" } });
    finish(exportResponse());
    await rejected;
  });
});
