import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Session, User } from "../../types";
import { rememberWorkspaceSlug } from "../../lib/workspacePreference";
import { AuthScreen } from "./AuthScreen";

const mocks = vi.hoisted(() => {
  const status = vi.fn();
  const acceptInvitation = vi.fn();
  const login = vi.fn();
  const bootstrap = vi.fn();

  return {
    status,
    acceptInvitation,
    login,
    bootstrap,
    api: {
      status,
      acceptInvitation,
      login,
      passwordSignIn: login,
      completeMfaSignIn: vi.fn(),
      startOidc: vi.fn(),
      bootstrap
    },
    setSession: vi.fn(),
    transportPolicyReady: true,
    accountActionsAllowed: true,
    insecureNetworkOrigin: false
  };
});

vi.mock("../../app/session", () => ({
  useSession: () => ({
    api: mocks.api,
    setSession: mocks.setSession,
    transportPolicyReady: mocks.transportPolicyReady,
    accountActionsAllowed:
      mocks.accountActionsAllowed && !mocks.insecureNetworkOrigin
  })
}));

vi.mock("../../lib/transportSecurity", () => ({
  isInsecureNonLoopbackOrigin: () => mocks.insecureNetworkOrigin
}));

const acceptedUser: User = {
  id: "user-1",
  tenant_id: "tenant-1",
  display_name: "Taylor Member",
  email: "taylor@example.test",
  account_type: "human",
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
    Reflect.deleteProperty(window, "kCommsDesktop");
    window.localStorage.clear();
    window.sessionStorage.clear();
    mocks.status.mockReset().mockResolvedValue({ capabilities: { bootstrap: false } });
    mocks.acceptInvitation.mockReset();
    mocks.login.mockReset();
    mocks.api.completeMfaSignIn.mockReset();
    mocks.api.startOidc.mockReset();
    mocks.bootstrap.mockReset();
    mocks.setSession.mockReset();
    mocks.transportPolicyReady = true;
    mocks.accountActionsAllowed = true;
    mocks.insecureNetworkOrigin = false;
    window.history.replaceState({}, "", "/app/");
  });

  it("desktop refuses corporate initiation before requesting any authorization URL", async () => {
    Object.defineProperty(window, "kCommsDesktop", { configurable: true, value: { version: 1 } });
    const user = userEvent.setup(); render(<MemoryRouter><AuthScreen /></MemoryRouter>);
    await user.click(screen.getByRole("button", { name: "Corporate sign in" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("authorized web client"); expect(mocks.api.startOidc).not.toHaveBeenCalled(); expect(mocks.setSession).not.toHaveBeenCalled();
    Reflect.deleteProperty(window, "kCommsDesktop");
  });

  it("shows one returning-user task and signs in with one submission", async () => {
    mocks.login.mockResolvedValue(session);
    const user = userEvent.setup();
    render(<MemoryRouter><AuthScreen /></MemoryRouter>);

    expect(screen.queryByRole("tablist")).not.toBeInTheDocument();
    expect(
      screen.queryByRole("heading", { name: /Chat, call, and share files/i })
    ).not.toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Sign in to your workspace" })).toBeVisible();
    expect(
      screen.getByRole("link", { name: /Start an instant room/i })
    ).toHaveAttribute("href", "/");

    await user.type(screen.getByLabelText("Workspace address"), "acme");
    await user.type(screen.getByLabelText("Email address"), "taylor@example.test");
    await user.type(screen.getByLabelText("Password"), "correct horse battery staple");
    await user.click(screen.getByRole("button", { name: "Sign in" }));

    expect(mocks.login).toHaveBeenCalledTimes(1);
    expect(mocks.login).toHaveBeenCalledWith({
      tenant_slug: "acme",
      email: "taylor@example.test",
      password: "correct horse battery staple",
      device: expect.objectContaining({ platform: "web" })
    });
    await waitFor(() => expect(mocks.setSession).toHaveBeenCalledWith(session));
  });

  it("keeps MFA proof in memory and establishes the session only after successful verification", async () => {
    mocks.login.mockResolvedValue({ mfa_required: true, challenge_token: "memory-only-proof", expires_in: 300 });
    mocks.api.completeMfaSignIn.mockResolvedValue(session);
    const user = userEvent.setup();
    render(<MemoryRouter><AuthScreen /></MemoryRouter>);

    await user.type(screen.getByLabelText("Workspace address"), "acme");
    await user.type(screen.getByLabelText("Email address"), "taylor@example.test");
    await user.type(screen.getByLabelText("Password"), "correct horse battery staple");
    await user.click(screen.getByRole("button", { name: /^Sign in$/ }));

    const code = await screen.findByLabelText("Authenticator or recovery code");
    expect(mocks.setSession).not.toHaveBeenCalled();
    expect(screen.queryByLabelText("Password")).not.toBeInTheDocument();
    expect(document.body).not.toHaveTextContent("memory-only-proof");
    expect(JSON.stringify(window.localStorage)).not.toContain("memory-only-proof");
    expect(JSON.stringify(window.sessionStorage)).not.toContain("memory-only-proof");
    await user.type(code, " 123456 ");
    await user.click(screen.getByRole("button", { name: "Verify and sign in" }));

    await waitFor(() => expect(mocks.setSession).toHaveBeenCalledExactlyOnceWith(session));
    expect(mocks.api.completeMfaSignIn).toHaveBeenCalledWith("memory-only-proof", "123456");
    expect(code).toHaveValue("");
  });

  it("keeps an invalid MFA proof signed out and allows a fresh sign-in challenge", async () => {
    mocks.login.mockResolvedValue({ mfa_required: true, challenge_token: "old-proof", expires_in: 300 });
    mocks.api.completeMfaSignIn.mockRejectedValue(new Error("The authenticator code is invalid or already used."));
    const user = userEvent.setup();
    render(<MemoryRouter><AuthScreen /></MemoryRouter>);
    await user.type(screen.getByLabelText("Workspace address"), "acme");
    await user.type(screen.getByLabelText("Email address"), "taylor@example.test");
    await user.type(screen.getByLabelText("Password"), "password");
    await user.click(screen.getByRole("button", { name: /^Sign in$/ }));
    await user.type(await screen.findByLabelText("Authenticator or recovery code"), "111111");
    await user.click(screen.getByRole("button", { name: "Verify and sign in" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("The authenticator code is invalid or already used.");
    expect(mocks.setSession).not.toHaveBeenCalled();
    await user.click(screen.getByRole("button", { name: "Start sign in again" }));
    expect(screen.getByLabelText("Password")).toHaveValue("");
    expect(screen.queryByLabelText("Authenticator or recovery code")).not.toBeInTheDocument();
    expect(mocks.setSession).not.toHaveBeenCalled();
  });

  it("expires an MFA challenge without submitting or establishing a session", async () => {
    mocks.login.mockResolvedValue({ mfa_required: true, challenge_token: "expired-proof", expires_in: 0 });
    const user = userEvent.setup();
    render(<MemoryRouter><AuthScreen /></MemoryRouter>);
    await user.type(screen.getByLabelText("Workspace address"), "acme");
    await user.type(screen.getByLabelText("Email address"), "taylor@example.test");
    await user.type(screen.getByLabelText("Password"), "password");
    await user.click(screen.getByRole("button", { name: /^Sign in$/ }));

    expect(await screen.findByRole("alert")).toHaveTextContent("This sign-in challenge expired.");
    expect(screen.getByLabelText("Authenticator or recovery code")).toBeDisabled();
    await user.click(screen.getByRole("button", { name: "Verify and sign in" }));
    expect(mocks.api.completeMfaSignIn).not.toHaveBeenCalled();
    expect(mocks.setSession).not.toHaveBeenCalled();
  });

  it.each(["http://idp.example.test/authorize", "https://user:secret@idp.example.test/authorize", "javascript:alert(1)"])("rejects the unsafe corporate authorization address %s", async authorization_url => {
    mocks.api.startOidc.mockResolvedValue({ authorization_url });
    const user = userEvent.setup();
    render(<MemoryRouter><AuthScreen /></MemoryRouter>);
    await user.type(screen.getByLabelText("Workspace address"), "acme");
    await user.click(screen.getByRole("button", { name: "Corporate sign in" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("Corporate sign in returned an invalid address.");
    expect(mocks.api.startOidc).toHaveBeenCalledWith("acme", "/app/");
    expect(mocks.setSession).not.toHaveBeenCalled();
    expect(window.location.pathname).toBe("/app/");
  });

  it("blocks credential submission on an unencrypted non-loopback origin", async () => {
    mocks.insecureNetworkOrigin = true;
    const user = userEvent.setup();
    render(<MemoryRouter><AuthScreen /></MemoryRouter>);

    expect(
      screen.getByText("HTTPS is required for account access.")
    ).toBeVisible();
    expect(screen.getByLabelText("Workspace address")).toBeDisabled();
    expect(screen.getByLabelText("Email address")).toBeDisabled();
    expect(screen.getByLabelText("Password")).toBeDisabled();
    const submit = screen.getByRole("button", { name: "Sign in" });
    expect(submit).toBeDisabled();
    await user.click(submit);
    expect(mocks.login).not.toHaveBeenCalled();

    await user.click(screen.getByRole("button", { name: "Use invitation code" }));
    expect(screen.getByLabelText("Invitation code")).toBeDisabled();
    expect(screen.getByLabelText("Your name")).toBeDisabled();
    expect(screen.getByLabelText("Create password")).toBeDisabled();
  });

  it("blocks credential controls when the server denies them on loopback HTTP", () => {
    mocks.accountActionsAllowed = false;

    render(<MemoryRouter><AuthScreen /></MemoryRouter>);

    expect(
      screen.getByText("HTTPS is required for account access.")
    ).toBeVisible();
    expect(screen.getByLabelText("Email address")).toBeDisabled();
    expect(screen.getByLabelText("Password")).toBeDisabled();
    expect(screen.getByRole("button", { name: "Sign in" })).toBeDisabled();
  });

  it("disables every workspace-setup field on an unencrypted non-loopback origin", async () => {
    mocks.insecureNetworkOrigin = true;
    mocks.status.mockResolvedValue({ capabilities: { bootstrap: true } });
    window.history.replaceState({}, "", "/sign-in?setup=workspace");
    render(<MemoryRouter><AuthScreen /></MemoryRouter>);

    expect(
      await screen.findByRole("heading", { name: "Create your workspace" })
    ).toBeVisible();
    expect(screen.getByLabelText("Workspace name")).toBeDisabled();
    expect(screen.getByLabelText("Your name")).toBeDisabled();
    expect(screen.getByLabelText("Work email")).toBeDisabled();
    expect(screen.getByLabelText("Create password")).toBeDisabled();
    expect(screen.getByLabelText("Workspace address")).toBeDisabled();
    expect(
      screen.getByRole("button", { name: "Create workspace" })
    ).toBeDisabled();
    expect(mocks.bootstrap).not.toHaveBeenCalled();
  });

  it("uses the remembered non-secret workspace and keeps it editable", async () => {
    rememberWorkspaceSlug("acme");
    const user = userEvent.setup();
    render(<MemoryRouter><AuthScreen /></MemoryRouter>);

    expect(screen.queryByLabelText("Workspace address")).not.toBeInTheDocument();
    expect(screen.getByText("acme")).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Change" }));
    expect(screen.getByLabelText("Workspace address")).toHaveValue("acme");
    await waitFor(() => expect(screen.getByLabelText("Workspace address")).toHaveFocus());
  });

  it("opens an authorized setup link directly and creates the workspace in one form", async () => {
    mocks.status.mockResolvedValue({ capabilities: { bootstrap: true } });
    mocks.bootstrap.mockResolvedValue(session);
    window.history.replaceState({}, "", "/app/?setup=workspace");
    const user = userEvent.setup();
    render(<MemoryRouter><AuthScreen /></MemoryRouter>);

    expect(
      await screen.findByRole("heading", { name: "Create your workspace" })
    ).toBeVisible();
    await screen.findByRole("button", { name: "Create workspace" });
    expect(screen.queryByRole("tablist")).not.toBeInTheDocument();

    await user.type(screen.getByLabelText("Workspace name"), "North Star Team");
    expect(screen.getByLabelText("Workspace address")).toHaveValue("north-star-team");
    await user.type(screen.getByLabelText("Your name"), "Taylor Owner");
    await user.type(screen.getByLabelText("Work email"), "owner@example.test");
    await user.type(screen.getByLabelText("Create password"), "correct horse battery staple");
    await user.click(screen.getByRole("button", { name: "Create workspace" }));

    expect(mocks.bootstrap).toHaveBeenCalledTimes(1);
    expect(mocks.bootstrap).toHaveBeenCalledWith({
      tenant_name: "North Star Team",
      tenant_slug: "north-star-team",
      display_name: "Taylor Owner",
      email: "owner@example.test",
      password: "correct horse battery staple",
      device_name: expect.any(String),
      device_platform: "web"
    });
    await waitFor(() => expect(mocks.setSession).toHaveBeenCalledWith(session));
  });

  it("does not let an explicit setup URL bypass the server capability", async () => {
    window.history.replaceState({}, "", "/app/?setup=workspace");
    render(<MemoryRouter><AuthScreen /></MemoryRouter>);

    expect(
      await screen.findByText("Workspace creation is not available on this deployment.", {
        exact: false
      })
    ).toBeVisible();
    expect(screen.queryByRole("button", { name: "Create workspace" })).not.toBeInTheDocument();
  });

  it("accepts a fragment invitation with two fields, scrubs its secret, and signs in", async () => {
    mocks.acceptInvitation.mockResolvedValue(acceptedUser);
    mocks.login.mockResolvedValue(session);
    window.history.replaceState(
      {},
      "",
      "/app/#invitation_token=one-time-secret&tenant_slug=acme"
    );
    const user = userEvent.setup();
    render(<MemoryRouter><AuthScreen /></MemoryRouter>);

    expect(screen.getByRole("heading", { name: "Join your workspace" })).toBeVisible();
    expect(screen.queryByLabelText("Invitation code")).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Confirm password")).not.toBeInTheDocument();
    expect(document.body).not.toHaveTextContent("one-time-secret");
    await waitFor(() => expect(document.title).toBe("Invitation | K-Comms"));
    expect(screen.getByText("Invitation view")).toHaveAttribute("aria-live", "polite");

    await user.type(screen.getByLabelText("Your name"), "Taylor Member");
    await user.type(screen.getByLabelText("Create password"), "correct horse battery staple");
    await user.click(screen.getByRole("button", { name: "Join workspace" }));

    expect(mocks.acceptInvitation).toHaveBeenCalledTimes(1);
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

  it("does not install an auto-login session that differs from the accepted identity", async () => {
    mocks.acceptInvitation.mockResolvedValue(acceptedUser);
    mocks.login.mockResolvedValue({
      ...session,
      tenant: { ...session.tenant, id: "tenant-2", slug: "other" },
      user: { ...acceptedUser, id: "user-9", tenant_id: "tenant-2" }
    });
    window.history.replaceState(
      {},
      "",
      "/app/#invitation_token=one-time-secret&tenant_slug=other"
    );
    const user = userEvent.setup();
    render(<MemoryRouter><AuthScreen /></MemoryRouter>);

    await user.type(screen.getByLabelText("Your name"), "Taylor Member");
    await user.type(screen.getByLabelText("Create password"), "correct horse battery staple");
    await user.click(screen.getByRole("button", { name: "Join workspace" }));

    await waitFor(() => expect(mocks.login).toHaveBeenCalledTimes(1));
    expect(mocks.setSession).not.toHaveBeenCalled();
    expect(await screen.findByRole("status")).toHaveTextContent(
      "the workspace link did not match the accepted account"
    );
    expect(screen.getByLabelText("Workspace address")).toHaveValue("");
  });

  it("preserves a one-form manual-code fallback and prefills sign-in after a network failure", async () => {
    mocks.acceptInvitation.mockResolvedValue(acceptedUser);
    mocks.login.mockRejectedValue(new Error("network unavailable"));
    const user = userEvent.setup();
    render(<MemoryRouter><AuthScreen /></MemoryRouter>);

    expect(screen.getByRole("group", { name: "Other ways to continue" })).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Use invitation code" }));
    await user.type(screen.getByLabelText("Invitation code"), "one-time-secret");
    await user.type(screen.getByLabelText("Workspace address"), "acme");
    await user.type(screen.getByLabelText("Your name"), "Taylor Member");
    await user.type(screen.getByLabelText("Create password"), "correct horse battery staple");
    await user.click(screen.getByRole("button", { name: "Join workspace" }));

    expect(await screen.findByRole("status")).toHaveTextContent("Invitation accepted");
    expect(screen.queryByLabelText("Workspace address")).not.toBeInTheDocument();
    expect(screen.getByText("acme")).toBeVisible();
    expect(screen.getByLabelText("Email address")).toHaveValue("taylor@example.test");
    expect(screen.getByLabelText("Password")).toHaveValue("");
    expect(document.body).not.toHaveTextContent("one-time-secret");

    await user.click(screen.getByRole("button", { name: "Use invitation code" }));
    expect(screen.getByLabelText("Invitation code")).toHaveValue("");
  });
});
