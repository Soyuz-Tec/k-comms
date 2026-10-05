import { render, waitFor, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import type * as Router from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { OidcCallback } from "./OidcCallback";

const mocks = vi.hoisted(() => ({
  api: { completeOidc: vi.fn(), completeOidcLink: vi.fn() },
  setSession: vi.fn(), navigate: vi.fn()
}));
vi.mock("../../app/session", () => ({ useSession: () => ({ api: mocks.api, setSession: mocks.setSession }) }));
vi.mock("react-router", async (importOriginal) => ({
  ...await importOriginal<typeof Router>(), useNavigate: () => mocks.navigate
}));

beforeEach(() => {
  vi.restoreAllMocks();
  for (const method of Object.values(mocks.api)) method.mockReset();
  mocks.setSession.mockReset(); mocks.navigate.mockReset();
  sessionStorage.clear();
  window.history.replaceState({}, "", "/sign-in/oidc-callback?code=private-code&state=one-use-state");
});
function showCallback() { render(<MemoryRouter><OidcCallback /></MemoryRouter>); }

describe("corporate identity callback", () => {
  it("scrubs authorization credentials and preserves only recognized member navigation fields", async () => {
    const session = { access_token: "fixture-access", refresh_token: "fixture-refresh" };
    mocks.api.completeOidc.mockImplementation(async () => {
      expect(window.location.search).toBe("");
      return { session, return_to: "/app/settings?section=security&token=discard" };
    });
    showCallback();
    await waitFor(() => expect(mocks.navigate).toHaveBeenCalledWith("/app/settings?section=security", { replace: true }));
    expect(mocks.api.completeOidc).toHaveBeenCalledWith("private-code", "one-use-state");
    expect(mocks.setSession).toHaveBeenCalledWith(session);
  });

  it.each(["/app//foreign.example.test", "/app/../sign-in", "https://foreign.example.test/app"])("rejects unsafe return destination %s", async (return_to) => {
    mocks.api.completeOidc.mockResolvedValue({ session: {}, return_to });
    showCallback();
    await waitFor(() => expect(mocks.navigate).toHaveBeenCalledWith("/app/", { replace: true }));
  });

  it("completes a corporate link or step-up using the existing authenticated session", async () => {
    sessionStorage.setItem("kcomms:oidc-link", "1");
    mocks.api.completeOidcLink.mockResolvedValue({ linked: true, return_to: "/app/settings?section=security" });
    showCallback();
    await waitFor(() => expect(mocks.navigate).toHaveBeenCalled());
    expect(mocks.api.completeOidcLink).toHaveBeenCalledWith("private-code", "one-use-state");
    expect(mocks.api.completeOidc).not.toHaveBeenCalled();
    expect(mocks.setSession).not.toHaveBeenCalled();
    expect(sessionStorage.getItem("kcomms:oidc-link")).toBeNull();
  });

  it("fails usefully when the browser cannot access binding state", async () => {
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => { throw new Error("Blocked"); });
    showCallback();
    expect(await screen.findByRole("alert")).toHaveTextContent("Browser storage is unavailable");
    expect(mocks.api.completeOidc).not.toHaveBeenCalled();
    expect(window.location.search).toBe("");
  });
});
