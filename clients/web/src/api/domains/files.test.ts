import { describe, expect, it, vi } from "vitest";
import type { ApiRequest } from "../contracts";
import { createFilesApi } from "./files";

describe("Files API filters", () => {
  it("encodes filename, complete category, conversation, and cursor independently", async () => {
    const request = vi.fn().mockResolvedValue({ data: [], page: {} });
    const api = createFilesApi(request as ApiRequest, { attachmentContentType: () => "text/plain" });
    await api.files({ q: "  report & notes  ", category: "images", conversation_id: "room/1", cursor: "older+/=", limit: 300 });
    expect(request).toHaveBeenCalledWith("/api/v1/files?scope=recent&limit=100&q=report+%26+notes&category=images&conversation_id=room%2F1&cursor=older%2B%2F%3D");
  });
  it("forwards optional safety scan filters while preserving the no-filter endpoint", async () => {
    const request = vi.fn().mockResolvedValue({ data: [] });
    const api = createFilesApi(request as ApiRequest, { attachmentContentType: () => "text/plain" });
    await api.attachmentSafety();
    await api.attachmentSafety({ scan_status: "failed", limit: 400 });
    expect(request.mock.calls.map(([path]) => path)).toEqual(["/api/v1/admin/attachment-safety", "/api/v1/admin/attachment-safety?scan_status=failed&limit=100"]);
  });

});
