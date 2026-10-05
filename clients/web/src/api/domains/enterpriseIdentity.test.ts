import { describe, expect, it, vi } from "vitest";
import type { ApiRequest } from "../contracts";
import { createEnterpriseIdentityApi } from "./enterpriseIdentity";

describe("enterprise identity API", () => {
  it("keeps a factor challenge separate from a session and completes with an explicit code", async () => {
    const challenge = { mfa_required: true, challenge_token: "one-use-challenge", expires_in: 300 };
    const session = { access_token: "access", refresh_token: "refresh" };
    const request = vi.fn().mockResolvedValueOnce(challenge).mockResolvedValueOnce(session);
    const received = vi.fn((value) => ({ ...value, received_at: 123 }));
    const api = createEnterpriseIdentityApi(request as ApiRequest, received);
    const input = { tenant_slug: "acme", email: "member@example.test", password: "password", device: { name: "Browser", platform: "web" as const } };
    expect(await api.passwordSignIn(input)).toEqual(challenge);
    expect(received).not.toHaveBeenCalled();
    expect(await api.completeMfaSignIn(challenge.challenge_token, "123456")).toEqual({ ...session, received_at: 123 });
    expect(JSON.parse(request.mock.calls[1]![1]!.body)).toEqual({ challenge_token: challenge.challenge_token, code: "123456" });
  });

  it("includes browser binding cookies only for the OIDC exchange and sends no email-link key", async () => {
    const request = vi.fn().mockResolvedValue({ authorization_url: "https://issuer.example.test/authorize" });
    const api = createEnterpriseIdentityApi(request as ApiRequest, (value) => value);
    await api.startOidc("acme", "/app/files");
    await api.linkOidc("acme");
    expect(request).toHaveBeenCalledTimes(2);
    for (const [, options] of request.mock.calls) expect(options!.credentials).toBe("include");
    expect(JSON.parse(request.mock.calls[0]![1]!.body)).toEqual({ tenant_slug: "acme", return_to: "/app/files" });
    expect(JSON.parse(request.mock.calls[1]![1]!.body)).not.toHaveProperty("email");
  });
});
