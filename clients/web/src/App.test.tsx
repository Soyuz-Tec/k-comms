import { render, screen, waitFor } from "@testing-library/react";
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

vi.mock("./app/ProductShell", async () => {
  const { Outlet } = await import("react-router");
  return { ProductShell: () => <Outlet /> };
});
vi.mock("./app/workspace-data", () => ({ WorkspaceDataProvider: ({ children }: { children: React.ReactNode }) => children }));
vi.mock("./app/step-up", () => ({ StepUpProvider: ({ children }: { children: React.ReactNode }) => children }));
vi.mock("./features/files/FilesPage", () => ({ FilesPage: () => <h1>Shared files route</h1> }));
vi.mock("./features/whiteboard/WhiteboardPage", () => ({ WhiteboardPage: () => <h1>Whiteboard route</h1> }));
vi.mock("./features/directory/DirectoryPage", () => ({ DirectoryPage: () => <h1>Directory route</h1> }));
vi.mock("./features/telephony/PhonePage", () => ({ PhonePage: () => <h1>Phone route</h1> }));
vi.mock("./features/meetings/MeetingsPage", () => ({ MeetingsPage: () => <h1>Meetings route</h1> }));
vi.mock("./features/chat/SavedItemsPage", () => ({ SavedItemsPage: () => <h1>Saved items route</h1> }));
vi.mock("./features/you/YouPage", () => ({ YouPage: () => <h1>You route</h1> }));

vi.mock("./features/instant-room/InstantRoomPage", () => ({
  InstantRoomPage: ({
    authenticationGateway
  }: {
    authenticationGateway?: React.ReactNode;
  }) => (
    <main>
      <h1>Instant front door</h1>
      {authenticationGateway}
    </main>
  )
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

  it.each([["/app/meetings?meeting=meeting-1", "Meetings route"], ["/app/saved", "Saved items route"]])("opens the member destination %s", async (path, heading) => {
    window.history.replaceState({}, "", path);
    render(<App />);
    expect(await screen.findByRole("heading", { name: heading })).toBeVisible();
    expect(window.location.pathname + window.location.search).toBe(path);
  });

  it("preserves the security section and fragment when a corporate callback returns to legacy settings", async () => {
    window.history.replaceState({}, "", "/app/settings?section=security#account");
    render(<App />);
    expect(await screen.findByRole("heading", { name: "You route" })).toBeVisible();
    expect(window.location.pathname + window.location.search + window.location.hash).toBe("/app/you?section=security#account");
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

  it.each([true, false])("preserves explicit workspace setup while respecting bootstrap capability %s", async (enabled) => {
    appHarness.session = null;
    appHarness.api.status.mockResolvedValue({ capabilities: { bootstrap: enabled } });
    window.history.replaceState({}, "", "/app/?setup=workspace&token=unrelated-secret#guest=guest-secret");

    render(<App />);

    if (enabled) {
      expect(await screen.findByRole("heading", { name: "Create your workspace" })).toBeVisible();
      expect(screen.getByRole("button", { name: "Create workspace" })).toBeVisible();
    } else {
      expect(await screen.findByText(/Workspace creation is not available on this deployment\./)).toBeVisible();
      expect(screen.queryByRole("button", { name: "Create workspace" })).not.toBeInTheDocument();
    }
    expect(window.location.pathname + window.location.search + window.location.hash).toBe("/sign-in?setup=workspace");
    expect(window.history.state.usr.returnTo).toBe("/app/");
    expect(document.body).not.toHaveTextContent("unrelated-secret");
    expect(document.body).not.toHaveTextContent("guest-secret");
  });

  it.each(["other", "workspace&setup=other", "workspace%20"])("rejects an unvalidated setup selector %s", async (selector) => {
    appHarness.session = null;
    window.history.replaceState({}, "", `/app/?setup=${selector}`);

    render(<App />);

    expect(await screen.findByRole("heading", { name: "Sign in to your workspace" })).toBeVisible();
    expect(window.location.pathname + window.location.search).toBe("/sign-in");
  });

  it("returns a signed-in member to a safe conversation deep link", () => {
    expect(
      memberAppTarget(
        "?conversation=conversation-1&message=message-2&invitation_token=secret"
      )
    ).toBe("/app/?conversation=conversation-1&message=message-2");
    expect(memberAppTarget("?invitation_token=secret")).toBe("/app/");
  });

  it.each([
    ["/app/files?conversation=room-1&file=file-1", "Shared files route"],
    ["/app/whiteboard?conversation=room-1&focus_elements=shape-1", "Whiteboard route"],
    ["/app/directory", "Directory route"],
    ["/app/calls/phone", "Phone route"]
  ])("returns to %s after sign-in without placing the target in the sign-in URL", async (target, heading) => {
    appHarness.session = null;
    window.history.replaceState({}, "", target);
    const view = render(<App />);
    await screen.findByRole("heading", { name: "Sign in to your workspace" });
    expect(window.location.pathname + window.location.search + window.location.hash).toBe("/sign-in");
    appHarness.session = { access_token: "member-access", refresh_token: "member-refresh" };
    view.rerender(<App />);
    await screen.findByRole("heading", { name: heading });
    expect(window.location.pathname + window.location.search).toBe(target);
  });

  it("preserves a validated workspace hint while returning to the requested file", async () => {
    appHarness.session = null;
    window.history.replaceState({}, "", "/app/files?tenant_slug=acme&file=file-1&guest_token=query-secret#guest=fragment-secret");
    const view = render(<App />);

    await screen.findByRole("heading", { name: "Sign in to your workspace" });
    expect(screen.getByText("acme")).toBeVisible();
    expect(window.location.pathname + window.location.search + window.location.hash).toBe("/sign-in?tenant_slug=acme");
    expect(window.history.state.usr.returnTo).toBe("/app/files?file=file-1");
    expect(JSON.stringify(window.history.state)).not.toContain("secret");

    appHarness.session = { access_token: "member-access", refresh_token: "member-refresh" };
    view.rerender(<App />);
    await screen.findByRole("heading", { name: "Shared files route" });
    expect(window.location.pathname + window.location.search + window.location.hash).toBe("/app/files?file=file-1");
  });

  it.each(["https%3A%2F%2Foutside.example", "acme%26guest_token%3Dsecret"])("drops invalid workspace hint %s and unrelated gateway credentials", async (slug) => {
    appHarness.session = null;
    window.history.replaceState({}, "", `/app/files?tenant_slug=${slug}&file=file-1&guest_token=query-secret#guest=fragment-secret`);

    render(<App />);

    await screen.findByRole("heading", { name: "Sign in to your workspace" });
    expect(window.location.pathname + window.location.search + window.location.hash).toBe("/sign-in");
    expect(window.history.state.usr.returnTo).toBe("/app/files?file=file-1");
    expect(document.body).not.toHaveTextContent("secret");
  });

  it("returns guest continuation through navigation state without putting its bearer in the URL", async () => {
    window.history.replaceState({ usr: { returnTo: "/join", guestToken: "room-secret" }, key: "signin", idx: 0 }, "", "/sign-in");
    render(<App />);
    await screen.findByRole("heading", { name: "Guest join route" });
    expect(window.location.pathname + window.location.search + window.location.hash).toBe("/join");
    expect(window.history.state.usr.guestToken).toBe("room-secret");
  });

  it("retains safe return state while an invitation token is scrubbed", async () => {
    appHarness.session = null;
    window.history.replaceState({ usr: { returnTo: "/app/files?file=file-1" }, key: "invite", idx: 0 }, "", "/sign-in#invitation_token=secret");
    const view = render(<App />);
    await waitFor(() => expect(window.location.hash).toBe(""));
    expect(window.history.state.usr).toEqual({ returnTo: "/app/files?file=file-1" });
    appHarness.session = { access_token: "member-access", refresh_token: "member-refresh" };
    view.rerender(<App />);
    await screen.findByRole("heading", { name: "Shared files route" });
    expect(window.location.pathname + window.location.search).toBe("/app/files?file=file-1");
  });

  it.each([
    ["/app/?invitation_token=invitation-secret&tenant_slug=acme&setup=workspace&conversation=room-1&guest_token=query-secret#guest=fragment-secret&token=reset-secret", "/sign-in?tenant_slug=acme&setup=workspace"],
    ["/app/?guest_token=query-secret&conversation=room-1&setup=workspace&setup=other#invitation_token=invitation-secret&tenant_slug=acme&guest_token=fragment-secret&token=reset-secret", "/sign-in#tenant_slug=acme"]
  ])("limits invitation gateway selectors and immediately scrubs the token from %s", async (entry, target) => {
    appHarness.session = null;
    appHarness.transportPolicyReady = false;
    window.history.replaceState({}, "", entry);

    render(<App />);

    expect(await screen.findByRole("heading", { name: "Join your workspace" })).toBeVisible();
    await waitFor(() => expect(window.location.pathname + window.location.search + window.location.hash).toBe(target));
    expect(window.history.state.usr.returnTo).toBe("/app/?conversation=room-1");
    expect(screen.getByRole("button", { name: "Join workspace" })).toBeDisabled();
    for (const secret of ["invitation-secret", "query-secret", "fragment-secret", "reset-secret"]) {
      expect(document.body).not.toHaveTextContent(secret);
      expect(window.location.href).not.toContain(secret);
      expect(JSON.stringify(window.history.state)).not.toContain(secret);
    }
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
