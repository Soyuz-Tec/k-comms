import { fireEvent, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, useLocation } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "../../api";
import { ForgotPasswordPage, ResetPasswordPage } from "./PasswordRecoveryPages";

const api = vi.hoisted(() => ({
  requestPasswordRecovery: vi.fn(),
  resetPassword: vi.fn()
}));
const transport = vi.hoisted(() => ({
  transportPolicyReady: true,
  accountActionsAllowed: true,
  insecureNetworkOrigin: false
}));
vi.mock("../../app/session", () => ({
  useSession: () => ({
    api,
    transportPolicyReady: transport.transportPolicyReady,
    accountActionsAllowed:
      transport.accountActionsAllowed && !transport.insecureNetworkOrigin
  })
}));
vi.mock("../../lib/transportSecurity", () => ({
  isInsecureNonLoopbackOrigin: () => transport.insecureNetworkOrigin
}));

function LocationProbe() {
  return <output data-testid="location">{useLocation().pathname}</output>;
}

describe("password recovery pages", () => {
  beforeEach(() => {
    api.requestPasswordRecovery.mockReset();
    api.resetPassword.mockReset();
    transport.transportPolicyReady = true;
    transport.accountActionsAllowed = true;
    transport.insecureNetworkOrigin = false;
    window.localStorage.clear();
    window.sessionStorage.clear();
    window.history.replaceState({}, "", "/");
  });

  it("shows the same non-enumerating confirmation after a recovery request", async () => {
    api.requestPasswordRecovery.mockResolvedValue(undefined);
    const user = userEvent.setup();
    render(<MemoryRouter><ForgotPasswordPage /></MemoryRouter>);
    expect(screen.getByRole("link", { name: "Back to sign in" })).toHaveAttribute("href", "/sign-in");
    await user.type(screen.getByLabelText("Workspace slug"), "acme");
    await user.type(screen.getByLabelText("Email address"), "missing@example.test");
    await user.click(screen.getByRole("button", { name: "Send reset instructions" }));

    expect(await screen.findByRole("heading", { name: "Check your email" })).toBeVisible();
    expect(screen.getByText(/If an account matches those details/)).toBeVisible();
    expect(screen.queryByText("missing@example.test")).not.toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Return to sign in" })).toHaveAttribute("href", "/sign-in");
  });

  it("does not send recovery credentials over unencrypted non-loopback HTTP", () => {
    transport.insecureNetworkOrigin = true;
    render(<MemoryRouter><ForgotPasswordPage /></MemoryRouter>);

    expect(
      screen.getByText("HTTPS is required for account recovery.")
    ).toBeVisible();
    expect(screen.getByLabelText("Email address")).toBeDisabled();
    expect(
      screen.getByRole("button", { name: "Send reset instructions" })
    ).toBeDisabled();

    fireEvent.submit(
      screen
        .getByRole("button", { name: "Send reset instructions" })
        .closest("form") as HTMLFormElement
    );
    expect(api.requestPasswordRecovery).not.toHaveBeenCalled();
  });

  it("does not expose recovery credentials when the server denies them on loopback HTTP", () => {
    transport.accountActionsAllowed = false;

    render(<MemoryRouter><ForgotPasswordPage /></MemoryRouter>);

    expect(
      screen.getByText("HTTPS is required for account recovery.")
    ).toBeVisible();
    expect(screen.getByLabelText("Email address")).toBeDisabled();
    expect(
      screen.getByRole("button", { name: "Send reset instructions" })
    ).toBeDisabled();
  });

  it("scrubs the token immediately, keeps it out of storage, and clears it after a successful reset", async () => {
    api.resetPassword.mockResolvedValue(undefined);
    window.history.replaceState({}, "", "/reset-password?utm_source=email#token=top-secret-token&campaign=spring");
    const user = userEvent.setup();
    render(
      <MemoryRouter>
        <ResetPasswordPage />
        <LocationProbe />
      </MemoryRouter>
    );

    expect(window.location.search).toBe("?utm_source=email");
    expect(window.location.hash).toBe("#campaign=spring");
    expect(JSON.stringify(window.localStorage)).not.toContain("top-secret-token");
    expect(JSON.stringify(window.sessionStorage)).not.toContain("top-secret-token");
    await user.type(screen.getByLabelText(/^New password/), "correct horse battery staple");
    await user.type(screen.getByLabelText("Confirm new password"), "correct horse battery staple");
    await user.click(screen.getByRole("button", { name: "Update password" }));

    expect(api.resetPassword).toHaveBeenCalledWith({ token: "top-secret-token", new_password: "correct horse battery staple" });
    expect(await screen.findByRole("heading", { name: "Password updated" })).toBeVisible();
    expect(screen.queryByLabelText(/^New password/)).not.toBeInTheDocument();
    const signIn = screen.getByRole("link", { name: "Sign in" });
    expect(signIn).toHaveAttribute("href", "/sign-in");
    await user.click(signIn);
    expect(screen.getByTestId("location")).toHaveTextContent("/sign-in");
  });

  it("does not send a new password over unencrypted non-loopback HTTP", () => {
    transport.insecureNetworkOrigin = true;
    window.history.replaceState(
      {},
      "",
      "/reset-password#token=never-send-over-http"
    );
    render(<MemoryRouter><ResetPasswordPage /></MemoryRouter>);

    expect(screen.getByLabelText(/^New password/)).toBeDisabled();
    expect(screen.getByLabelText("Confirm new password")).toBeDisabled();
    expect(
      screen.getByRole("button", { name: "Update password" })
    ).toBeDisabled();

    fireEvent.submit(
      screen
        .getByRole("button", { name: "Update password" })
        .closest("form") as HTMLFormElement
    );
    expect(api.resetPassword).not.toHaveBeenCalled();
  });

  it("renders a safe server-policy error without exposing the reset token", async () => {
    api.resetPassword.mockRejectedValue(new ApiError(422, "password_policy_violation", "unsafe detail", { minimum_length: 16 }));
    window.history.replaceState({}, "", "/reset-password?token=never-render-this");
    const user = userEvent.setup();
    render(<MemoryRouter><ResetPasswordPage /></MemoryRouter>);
    await user.type(screen.getByLabelText(/^New password/), "twelve-characters");
    await user.type(screen.getByLabelText("Confirm new password"), "twelve-characters");
    await user.click(screen.getByRole("button", { name: "Update password" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("at least 16 characters");
    expect(document.body).not.toHaveTextContent("never-render-this");
    expect(document.body).not.toHaveTextContent("unsafe detail");
  });

  it("clears the token for the backend's invalid_recovery_token response", async () => {
    api.resetPassword.mockRejectedValue(new ApiError(400, "invalid_recovery_token", "opaque token rejected"));
    window.history.replaceState({}, "", "/reset-password#token=expired-secret");
    const user = userEvent.setup();
    render(<MemoryRouter><ResetPasswordPage /></MemoryRouter>);
    await user.type(screen.getByLabelText(/^New password/), "correct horse battery staple");
    await user.type(screen.getByLabelText("Confirm new password"), "correct horse battery staple");
    await user.click(screen.getByRole("button", { name: "Update password" }));

    expect(await screen.findByRole("heading", { name: "Reset link unavailable" })).toBeVisible();
    expect(screen.getByRole("alert")).toHaveTextContent("invalid or expired");
    expect(screen.queryByLabelText(/^New password/)).not.toBeInTheDocument();
    expect(document.body).not.toHaveTextContent("expired-secret");
    expect(document.body).not.toHaveTextContent("opaque token rejected");
  });
});
