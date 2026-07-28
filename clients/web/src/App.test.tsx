import { render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import App, { memberAppTarget } from "./App";

const appHarness = vi.hoisted(() => {
  const status = vi.fn();
  return {
    transportPolicyReady: true,
    session: {
      access_token: "member-access",
      refresh_token: "member-refresh",
      token_type: "Bearer",
      expires_in: 900,
      tenant: { id: "tenant-1", name: "Acme", slug: "acme", status: "active" },
      user: {
        id: "user-1",
        tenant_id: "tenant-1",
        display_name: "Ada",
        role: "owner",
        status: "active"
      },
      device: { id: "device-1", user_id: "user-1", name: "Browser", platform: "web" }
    } as object | null,
    api: {
      status,
      acceptInvitation: vi.fn(),
      bootstrap: vi.fn(),
      login: vi.fn()
    },
    setSession: vi.fn()
  };
});

vi.mock("./app/session", () => ({
  SessionProvider: ({ children }: { children: React.ReactNode }) => children,
  useSession: () => ({
    session: appHarness.session,
    transportPolicyReady: appHarness.transportPolicyReady,
    accountActionsAllowed: appHarness.transportPolicyReady,
    api: appHarness.api,
    setSession: appHarness.setSession
  })
}));

vi.mock("./features/guest/GuestAccessPage", () => ({
  GuestAccessPage: () => <main><h1>Guest join route</h1></main>
}));

vi.mock("./features/instant-room/InstantRoomPage", () => ({
  InstantRoomPage: () => <main><h1>Instant front door</h1></main>
}));

describe("application route priority", () => {
  beforeEach(() => {
    appHarness.transportPolicyReady = true;
    appHarness.session = {
      access_token: "member-access",
      refresh_token: "member-refresh"
    };
    appHarness.api.status.mockReset().mockResolvedValue({
      capabilities: { bootstrap: false }
    });
    appHarness.setSession.mockReset();
    window.history.replaceState({}, "", "/join#guest=route-token");
  });

  it("renders /join before the authenticated product fallback", () => {
    render(<App />);

    expect(screen.getByRole("heading", { name: "Guest join route" })).toBeVisible();
    expect(screen.queryByText("Inbox")).not.toBeInTheDocument();
  });

  it("preserves a trailing-slash guest bearer route for both auth states", () => {
    for (const memberSession of [
      { access_token: "member-access", refresh_token: "member-refresh" },
      null
    ]) {
      appHarness.session = memberSession;
      window.history.replaceState({}, "", "/join/#guest=route-token");
      const view = render(<App />);

      expect(
        screen.getByRole("heading", { name: "Guest join route" })
      ).toBeVisible();
      expect(window.location.pathname).toBe("/join/");
      expect(window.location.hash).toBe("#guest=route-token");
      view.unmount();
    }
  });

  it("keeps / as the instant-room front door even for a signed-in member", () => {
    window.history.replaceState({}, "", "/");

    render(<App />);

    expect(
      screen.getByRole("heading", { name: "Instant front door" })
    ).toBeVisible();
  });

  it("redirects a signed-out /app visit to sign in", async () => {
    appHarness.session = null;
    window.history.replaceState({}, "", "/app");

    render(<App />);

    expect(
      await screen.findByRole("heading", { name: "Sign in to your workspace" })
    ).toBeVisible();
    expect(window.location.pathname).toBe("/sign-in");
  });

  it("returns a signed-in member to a safe conversation deep link", () => {
    expect(
      memberAppTarget(
        "?conversation=conversation-1&message=message-2&invitation_token=secret"
      )
    ).toBe("/app/?conversation=conversation-1&message=message-2");
    expect(memberAppTarget("?invitation_token=secret")).toBe("/app/");
  });

  it("canonicalizes a legacy account root before waiting for transport policy", async () => {
    appHarness.session = null;
    appHarness.transportPolicyReady = false;
    window.history.replaceState({}, "", "/app");

    render(<App />);

    expect(
      await screen.findByRole("heading", { name: "Loading K-Comms…" })
    ).toBeVisible();
    expect(window.location.pathname).toBe("/app/");
  });

  it("mounts and scrubs a reset token while transport policy is unresolved", () => {
    appHarness.session = null;
    appHarness.transportPolicyReady = false;
    window.history.replaceState(
      {},
      "",
      "/reset-password?campaign=summer#token=reset-secret"
    );

    render(<App />);

    expect(
      screen.getByRole("heading", { name: "Choose a new password" })
    ).toBeVisible();
    expect(window.location.search).toBe("?campaign=summer");
    expect(window.location.hash).toBe("");
    expect(screen.getByLabelText(/^New password/)).toBeDisabled();
    expect(document.body).not.toHaveTextContent("reset-secret");
  });

  it("redirects, mounts, and scrubs an invitation while policy is unresolved", async () => {
    appHarness.session = null;
    appHarness.transportPolicyReady = false;
    window.history.replaceState(
      {},
      "",
      "/app?invitation_token=invitation-secret&tenant_slug=acme"
    );

    render(<App />);

    expect(
      await screen.findByRole("heading", { name: "Join your workspace" })
    ).toBeVisible();
    expect(window.location.pathname).toBe("/sign-in");
    expect(window.location.search).toBe("?tenant_slug=acme");
    expect(screen.getByRole("button", { name: "Join workspace" })).toBeDisabled();
    expect(document.body).not.toHaveTextContent("invitation-secret");
  });

  it("preserves explicit sign-in and scrubs invitation entry credentials", () => {
    appHarness.session = null;
    window.history.replaceState({}, "", "/sign-in");
    const first = render(<App />);
    expect(
      screen.getByRole("heading", { name: "Sign in to your workspace" })
    ).toBeVisible();
    first.unmount();

    window.history.replaceState(
      {},
      "",
      "/app?invitation_token=invitation-secret"
    );
    render(<App />);
    expect(
      screen.getByRole("heading", { name: "Join your workspace" })
    ).toBeVisible();
    expect(window.location.pathname).toBe("/sign-in");
    expect(window.location.search).toBe("");
  });
});
