import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { EnterpriseSecuritySettings } from "./EnterpriseSecuritySettings";

const mocks = vi.hoisted(() => ({ allowed: true, api: { identitySecurity: vi.fn(), stepUp: vi.fn(), stepUpOidc: vi.fn(), enrollMfa: vi.fn(), confirmMfa: vi.fn(), disableMfa: vi.fn(), rotateMfaRecovery: vi.fn(), linkOidc: vi.fn() } }));
vi.mock("../../app/session", () => ({ useSession: () => ({ api: mocks.api, transportPolicyReady: true, accountActionsAllowed: mocks.allowed, session: { tenant: { slug: "acme" }, user: { email: "member@example.test" } } }) }));

beforeEach(() => { mocks.allowed = true; for (const method of Object.values(mocks.api)) method.mockReset(); });
describe("authenticator settings", () => {
  it("performs step-up before enrollment and returns recovery codes only after successful confirmation", async () => {
    const user = userEvent.setup();
    mocks.api.identitySecurity.mockResolvedValue({ mfa_enabled: false, recovery_codes_remaining: 0 });
    mocks.api.stepUp.mockResolvedValue({});
    mocks.api.enrollMfa.mockResolvedValue({ secret: "SYNTHETICSECRET", provisioning_uri: "otpauth://test" });
    mocks.api.confirmMfa.mockResolvedValue({ recovery_codes: ["recovery-one", "recovery-two"] });
    render(<EnterpriseSecuritySettings />);
    await user.type(screen.getByLabelText("Current password"), "current-password");
    await user.click(await screen.findByRole("button", { name: "Set up authenticator" }));
    expect(mocks.api.stepUp).toHaveBeenCalledWith("current-password", undefined);
    await screen.findByText("SYNTHETICSECRET");
    expect(screen.queryByRole("region", { name: "New recovery codes" })).not.toBeInTheDocument();
    await user.type(screen.getByLabelText("Authenticator code"), "123456");
    await user.click(screen.getByRole("button", { name: "Confirm authenticator" }));
    expect(mocks.api.confirmMfa).toHaveBeenCalledWith("123456");
    expect(await screen.findByRole("region", { name: "New recovery codes" })).toHaveTextContent("recovery-one");
    await user.click(screen.getByRole("button", { name: "I have stored the codes" }));
    expect(screen.queryByRole("region", { name: "New recovery codes" })).not.toBeInTheDocument();
  });

  it("does not disable an authenticator after failed step-up and preserves a useful error", async () => {
    const user = userEvent.setup();
    mocks.api.identitySecurity.mockResolvedValue({ mfa_enabled: true, recovery_codes_remaining: 8 });
    mocks.api.stepUp.mockRejectedValue(new Error("Factor verification failed"));
    render(<EnterpriseSecuritySettings />);
    await screen.findByText(/Authenticator enabled/);
    await user.type(screen.getByLabelText("Current password"), "current-password");
    await user.type(screen.getByLabelText("Step-up authenticator or recovery code"), "used-code");
    await user.type(screen.getByLabelText("New authenticator or separate recovery code for the change"), "second-code");
    await user.click(screen.getByRole("button", { name: "Disable authenticator" }));
    await waitFor(() => expect(screen.getByRole("alert")).toHaveTextContent("Factor verification failed"));
    expect(mocks.api.disableMfa).not.toHaveBeenCalled();
  });

  it.each(["http://issuer.example.test/authorize", "https://member:secret@issuer.example.test/authorize"])("rejects unsafe corporate verification addresses %s", async (authorization_url) => {
    const user = userEvent.setup();
    mocks.api.identitySecurity.mockResolvedValue({ mfa_enabled: false, recovery_codes_remaining: 0, authentication_method: "oidc" });
    mocks.api.stepUpOidc.mockResolvedValue({ authorization_url });
    render(<EnterpriseSecuritySettings />);
    await user.click(await screen.findByRole("button", { name: "Verify corporate session" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("invalid address");
    expect(sessionStorage.getItem("kcomms:oidc-link")).toBeNull();
  });

  it("keeps security credentials off an insecure connection", async () => {
    mocks.allowed = false;
    mocks.api.identitySecurity.mockResolvedValue({ mfa_enabled: false, recovery_codes_remaining: 0, authentication_method: "oidc" });
    render(<EnterpriseSecuritySettings />);
    await userEvent.click(await screen.findByRole("button", { name: "Verify corporate session" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("secure connection");
    expect(mocks.api.stepUpOidc).not.toHaveBeenCalled();
  });
});
