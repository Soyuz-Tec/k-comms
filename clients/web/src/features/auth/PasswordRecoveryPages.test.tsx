import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "../../api";
import { ForgotPasswordPage, ResetPasswordPage } from "./PasswordRecoveryPages";

const api = vi.hoisted(() => ({
  requestPasswordRecovery: vi.fn(),
  resetPassword: vi.fn()
}));
vi.mock("../../app/session", () => ({ useSession: () => ({ api }) }));

describe("password recovery pages", () => {
  beforeEach(() => {
    api.requestPasswordRecovery.mockReset();
    api.resetPassword.mockReset();
    window.localStorage.clear();
    window.sessionStorage.clear();
    window.history.replaceState({}, "", "/");
  });

  it("shows the same non-enumerating confirmation after a recovery request", async () => {
    api.requestPasswordRecovery.mockResolvedValue(undefined);
    const user = userEvent.setup();
    render(<MemoryRouter><ForgotPasswordPage /></MemoryRouter>);
    await user.type(screen.getByLabelText("Workspace slug"), "acme");
    await user.type(screen.getByLabelText("Email address"), "missing@example.test");
    await user.click(screen.getByRole("button", { name: "Send reset instructions" }));

    expect(await screen.findByRole("heading", { name: "Check your email" })).toBeVisible();
    expect(screen.getByText(/If an account matches those details/)).toBeVisible();
    expect(screen.queryByText("missing@example.test")).not.toBeInTheDocument();
  });

  it("scrubs the token immediately, keeps it out of storage, and clears it after a successful reset", async () => {
    api.resetPassword.mockResolvedValue(undefined);
    window.history.replaceState({}, "", "/reset-password?utm_source=email#token=top-secret-token&campaign=spring");
    const user = userEvent.setup();
    render(<MemoryRouter><ResetPasswordPage /></MemoryRouter>);

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
