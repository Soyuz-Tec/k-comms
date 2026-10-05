import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiClient } from "../../api";
import type { Session } from "../../types";
import { usageFixture } from "../../features/admin/usageReports.testSupport";

const session: Session = {
  access_token: "synthetic-access", refresh_token: "synthetic-refresh", token_type: "Bearer", expires_in: 900,
  tenant: { id: "synthetic-tenant", name: "Synthetic", slug: "synthetic", status: "active" },
  user: { id: "synthetic-owner", tenant_id: "synthetic-tenant", display_name: "Owner", role: "owner", status: "active" },
  device: { id: "synthetic-device", user_id: "synthetic-owner", name: "Browser", platform: "web" }
};
afterEach(() => vi.unstubAllGlobals());

describe("observed usage transport", () => {
  it("preserves explicit source unavailability and verifies actual export window/observation metadata", async () => {
    const fetchMock = vi.fn<typeof fetch>().mockResolvedValueOnce(new Response(JSON.stringify({ data: usageFixture() }), { headers: { "content-type": "application/json" } }))
      .mockResolvedValueOnce(new Response("synthetic safe aggregate CSV", { headers: { "content-type": "text/csv", "x-usage-from": "2000-01-01", "x-usage-through": "2000-01-02",
        "x-usage-time-zone": "UTC", "x-usage-observed-at": "2000-01-03T12:00:00Z", "x-usage-unavailable-sources": "2" } }));
    vi.stubGlobal("fetch", fetchMock);
    const api = new ApiClient("https://synthetic.example.test", session, vi.fn());
    const report = await api.usageReport({ from: "2000-01-01", through: "2000-01-02" });
    expect(report.sources.attachments).toEqual({ status: "unavailable", data: null });
    const file = await api.exportUsageReport({ from: report.range.from, through: report.range.through });
    expect(file.usage).toEqual({ from: "2000-01-01", through: "2000-01-02", timeZone: "UTC", observedAt: "2000-01-03T12:00:00Z", unavailableSources: 2 });
    expect(file).not.toHaveProperty("count");
    expect(fetchMock.mock.calls.map(([url]) => String(url))).toEqual([
      "https://synthetic.example.test/api/v1/admin/usage?from=2000-01-01&through=2000-01-02",
      "https://synthetic.example.test/api/v1/admin/usage/export?from=2000-01-01&through=2000-01-02"
    ]);
  });

  it("rejects an exported window that differs from the applied window", async () => {
    vi.stubGlobal("fetch", vi.fn<typeof fetch>().mockResolvedValue(new Response("synthetic aggregate CSV", { headers: {
      "x-usage-from": "2000-01-01", "x-usage-through": "2000-01-03", "x-usage-time-zone": "UTC", "x-usage-observed-at": "2000-01-03T12:00:00Z", "x-usage-unavailable-sources": "0"
    } })));
    await expect(new ApiClient("https://synthetic.example.test", session, vi.fn()).exportUsageReport({ from: "2000-01-01", through: "2000-01-02" })).rejects.toMatchObject({ code: "invalid_usage_export" });
  });
});
