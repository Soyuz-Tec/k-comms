import { render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import App from "./App";

const appHarness = vi.hoisted(() => ({
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
  } as object | null
}));

vi.mock("./app/session", () => ({
  SessionProvider: ({ children }: { children: React.ReactNode }) => children,
  useSession: () => ({
    session: appHarness.session
  })
}));

vi.mock("./features/guest/GuestAccessPage", () => ({
  GuestAccessPage: () => <main><h1>Guest join route</h1></main>
}));

vi.mock("./features/instant-room/InstantRoomPage", () => ({
  InstantRoomPage: () => <main><h1>Instant front door</h1></main>
}));

vi.mock("./features/auth/AuthScreen", () => ({
  AuthScreen: () => <main><h1>Explicit sign in</h1></main>
}));

describe("application route priority", () => {
  beforeEach(() => {
    appHarness.session = {
      access_token: "member-access",
      refresh_token: "member-refresh"
    };
    window.history.replaceState({}, "", "/join#guest=route-token");
  });

  it("renders /join before the authenticated product fallback", () => {
    render(<App />);

    expect(screen.getByRole("heading", { name: "Guest join route" })).toBeVisible();
    expect(screen.queryByText("Inbox")).not.toBeInTheDocument();
  });

  it("keeps / as the instant-room front door even for a signed-in member", () => {
    window.history.replaceState({}, "", "/");

    render(<App />);

    expect(
      screen.getByRole("heading", { name: "Instant front door" })
    ).toBeVisible();
  });

  it("redirects a signed-out /app visit to the instant front door", async () => {
    appHarness.session = null;
    window.history.replaceState({}, "", "/app");

    render(<App />);

    expect(
      await screen.findByRole("heading", { name: "Instant front door" })
    ).toBeVisible();
    expect(window.location.pathname).toBe("/");
  });

  it("preserves explicit sign-in and invitation/setup entry points", () => {
    appHarness.session = null;
    window.history.replaceState({}, "", "/sign-in");
    const first = render(<App />);
    expect(screen.getByRole("heading", { name: "Explicit sign in" })).toBeVisible();
    first.unmount();

    window.history.replaceState(
      {},
      "",
      "/app?invitation_token=invitation-secret"
    );
    render(<App />);
    expect(screen.getByRole("heading", { name: "Explicit sign in" })).toBeVisible();
  });
});
