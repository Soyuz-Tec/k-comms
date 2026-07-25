import { render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import App from "./App";

vi.mock("./app/session", () => ({
  SessionProvider: ({ children }: { children: React.ReactNode }) => children,
  useSession: () => ({
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
    }
  })
}));

vi.mock("./features/guest/GuestAccessPage", () => ({
  GuestAccessPage: () => <main><h1>Guest join route</h1></main>
}));

describe("application route priority", () => {
  beforeEach(() => {
    window.history.replaceState({}, "", "/join#guest=route-token");
  });

  it("renders /join before the authenticated product fallback", () => {
    render(<App />);

    expect(screen.getByRole("heading", { name: "Guest join route" })).toBeVisible();
    expect(screen.queryByText("Inbox")).not.toBeInTheDocument();
  });
});
