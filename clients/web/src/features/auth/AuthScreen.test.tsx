import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Session, User } from "../../types";
import { AuthScreen } from "./AuthScreen";

const mocks = vi.hoisted(() => ({
  status: vi.fn(),
  acceptInvitation: vi.fn(),
  login: vi.fn(),
  bootstrap: vi.fn(),
  setSession: vi.fn()
}));

vi.mock("../../app/session", () => ({
  useSession: () => ({
    api: {
      status: mocks.status,
      acceptInvitation: mocks.acceptInvitation,
      login: mocks.login,
      bootstrap: mocks.bootstrap
    },
    setSession: mocks.setSession
  })
}));

const acceptedUser: User = {
  id: "user-1",
  tenant_id: "tenant-1",
  display_name: "Taylor Member",
  email: "taylor@example.test",
  role: "member",
  status: "active",
  version: 1
};

const session = {
  access_token: "access",
  refresh_token: "refresh",
  token_type: "Bearer",
  expires_in: 900,
  tenant: { id: "tenant-1", name: "Acme", slug: "acme", status: "active" },
  user: acceptedUser,
  device: { id: "device-1", user_id: "user-1", name: "Test", platform: "web" }
} satisfies Session;

describe("AuthScreen", () => {
  beforeEach(() => {
    mocks.status.mockReset().mockResolvedValue({ capabilities: { bootstrap: false } });
    mocks.acceptInvitation.mockReset();
    mocks.login.mockReset();
    mocks.bootstrap.mockReset();
    mocks.setSession.mockReset();
    window.history.replaceState({}, "", "/app/");
  });

  it("supports roving keyboard focus and complete tab relationships", async () => {
    const user = userEvent.setup();
    render(<MemoryRouter><AuthScreen /></MemoryRouter>);

    const signIn = screen.getByRole("tab", { name: "Sign in" });
    const acceptInvite = screen.getByRole("tab", { name: "Accept invite" });
    expect(signIn).toHaveAttribute("tabindex", "0");
    expect(acceptInvite).toHaveAttribute("tabindex", "-1");
    expect(signIn).toHaveAttribute("aria-controls", "auth-login-panel");
    expect(screen.getByRole("tabpanel")).toHaveAttribute("aria-labelledby", "auth-login-tab");

    signIn.focus();
    await user.keyboard("{ArrowRight}");
    expect(acceptInvite).toHaveFocus();
    expect(acceptInvite).toHaveAttribute("aria-selected", "true");
    expect(acceptInvite).toHaveAttribute("tabindex", "0");
    expect(screen.getByRole("tabpanel")).toHaveAttribute("aria-labelledby", "auth-invite-tab");

    await user.keyboard("{Home}");
    expect(signIn).toHaveFocus();
    expect(signIn).toHaveAttribute("aria-selected", "true");
  });

  it("accepts a fragment invitation, scrubs its secret, and signs in with safe context", async () => {
    mocks.acceptInvitation.mockResolvedValue(acceptedUser);
    mocks.login.mockResolvedValue(session);
    window.history.replaceState({}, "", "/app/#invitation_token=one-time-secret&tenant_slug=acme");
    const user = userEvent.setup();
    render(<MemoryRouter><AuthScreen /></MemoryRouter>);

    expect(screen.getByLabelText("Invitation token")).toHaveValue("one-time-secret");
    expect(window.location.href).not.toContain("one-time-secret");
    expect(window.location.hash).toBe("#tenant_slug=acme");

    await user.type(screen.getByLabelText("Display name"), "Taylor Member");
    await user.type(screen.getByLabelText(/^Password$/), "correct horse battery staple");
    await user.type(screen.getByLabelText("Confirm password"), "correct horse battery staple");
    await user.click(screen.getByRole("button", { name: "Accept invitation" }));

    expect(mocks.acceptInvitation).toHaveBeenCalledWith({
      token: "one-time-secret",
      display_name: "Taylor Member",
      password: "correct horse battery staple"
    });
    expect(mocks.login).toHaveBeenCalledWith({
      tenant_slug: "acme",
      email: "taylor@example.test",
      password: "correct horse battery staple",
      device: expect.objectContaining({ platform: "web" })
    });
    await waitFor(() => expect(mocks.setSession).toHaveBeenCalledWith(session));
  });

  it("prefills the manual sign-in fallback when automatic sign-in cannot complete", async () => {
    mocks.acceptInvitation.mockResolvedValue(acceptedUser);
    mocks.login.mockRejectedValue(new Error("network unavailable"));
    window.history.replaceState({}, "", "/app/#invitation_token=one-time-secret&tenant_slug=acme");
    const user = userEvent.setup();
    render(<MemoryRouter><AuthScreen /></MemoryRouter>);

    await user.type(screen.getByLabelText("Display name"), "Taylor Member");
    await user.type(screen.getByLabelText(/^Password$/), "correct horse battery staple");
    await user.type(screen.getByLabelText("Confirm password"), "correct horse battery staple");
    await user.click(screen.getByRole("button", { name: "Accept invitation" }));

    expect(await screen.findByRole("status")).toHaveTextContent("Invitation accepted");
    expect(screen.getByLabelText("Workspace slug")).toHaveValue("acme");
    expect(screen.getByLabelText("Email address")).toHaveValue("taylor@example.test");
    expect(screen.getByLabelText("Password")).toHaveValue("");
    expect(document.body).not.toHaveTextContent("one-time-secret");
  });
});
