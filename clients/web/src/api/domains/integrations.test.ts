import { describe, expect, it, vi } from "vitest";
import type { ApiRequest } from "../contracts";
import { createIntegrationsApi } from "./integrations";

describe("Webhook updates", () => {
  it("uses the existing authenticated PATCH contract without generating a signing secret", async () => {
    const endpoint = { id: "endpoint-1", status: "active" };
    const request = vi.fn().mockResolvedValue({ data: endpoint });
    const api = createIntegrationsApi(request as ApiRequest);
    await expect(api.updateWebhook("endpoint/1", { status: "active" })).resolves.toEqual(endpoint);
    expect(request).toHaveBeenCalledWith("/api/v1/admin/webhooks/endpoint%2F1", { method: "PATCH", body: JSON.stringify({ status: "active" }) });
  });
});
