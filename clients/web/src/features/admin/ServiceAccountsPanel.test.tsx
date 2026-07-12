import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import type { ServiceAccount } from "../../types";
import { ServiceAccountsPanel } from "./ServiceAccountsPanel";

const runWithStepUp = vi.hoisted(() => <T,>(action: () => Promise<T>) => action());
vi.mock("../../app/step-up", () => ({
  useStepUp: () => ({ runWithStepUp }),
  stepUpWasCancelled: () => false
}));

const account: ServiceAccount = {
  id: "11111111-1111-4111-8111-111111111111",
  tenant_id: "tenant-1",
  user_id: "bot-user-1",
  device_id: "bot-device-1",
  name: "Release Bot",
  credential_prefix: "kcsa_11111111-1111-4111-8111-111111111111",
  secret_hint: "xYz1",
  scopes: ["conversations:read", "messages:read", "messages:write"],
  status: "active",
  expires_at: "2027-01-01T10:00:00Z",
  last_used_at: null,
  last_rotated_at: "2026-07-12T10:00:00Z",
  revoked_at: null,
  version: 1,
  inserted_at: "2026-07-12T10:00:00Z",
  updated_at: "2026-07-12T10:00:00Z"
};

describe("ServiceAccountsPanel", () => {
  it("creates a scoped non-login bot and guards its one-time credential", async () => {
    const createServiceAccount = vi.fn().mockResolvedValue({ account, credential: "kcsa_account.one-time-secret" });
    const api = { serviceAccounts: vi.fn().mockResolvedValue([]), createServiceAccount } as unknown as ApiClient;
    const onLifecycleChanged = vi.fn().mockResolvedValue(undefined);
    const user = userEvent.setup();
    render(<ServiceAccountsPanel api={api} onLifecycleChanged={onLifecycleChanged} />);

    await screen.findByText("No service accounts configured.");
    await user.type(screen.getByRole("textbox", { name: "Bot name" }), "Release Bot");
    await user.type(screen.getByRole("textbox", { name: "Creation reason" }), "Release automation");
    await user.click(screen.getByRole("button", { name: "Create service account" }));

    expect(await screen.findByText("kcsa_account.one-time-secret")).toBeVisible();
    expect(screen.getByRole("button", { name: "Create service account" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Rotate credential" })).toBeDisabled();
    expect(createServiceAccount).toHaveBeenCalledWith(expect.objectContaining({
      name: "Release Bot",
      reason: "Release automation",
      scopes: ["conversations:read", "messages:read", "messages:write"]
    }));
    expect(onLifecycleChanged).toHaveBeenCalledTimes(1);
  });

  it("rotates and revokes with the current optimistic version and an audited reason", async () => {
    const rotated = { ...account, version: 2, secret_hint: "nEw2" };
    const revoked = { ...rotated, version: 3, status: "revoked" as const, revoked_at: "2026-07-12T11:00:00Z" };
    const rotateServiceAccount = vi.fn().mockResolvedValue({ account: rotated, credential: "kcsa_account.rotated-secret" });
    const revokeServiceAccount = vi.fn().mockResolvedValue(revoked);
    const api = { serviceAccounts: vi.fn().mockResolvedValue([account]), rotateServiceAccount, revokeServiceAccount } as unknown as ApiClient;
    const onLifecycleChanged = vi.fn().mockResolvedValue(undefined);
    const prompt = vi.spyOn(window, "prompt").mockReturnValueOnce("Routine credential rotation").mockReturnValueOnce("Automation retired");
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(true);
    const user = userEvent.setup();
    render(<ServiceAccountsPanel api={api} onLifecycleChanged={onLifecycleChanged} />);

    await user.click(await screen.findByRole("button", { name: "Rotate credential" }));
    expect(rotateServiceAccount).toHaveBeenCalledWith(account.id, 1, "Routine credential rotation");
    expect(await screen.findByText("kcsa_account.rotated-secret")).toBeVisible();
    await user.click(screen.getByRole("button", { name: "I stored it" }));
    await user.click(screen.getByRole("button", { name: "Revoke" }));

    expect(revokeServiceAccount).toHaveBeenCalledWith(account.id, 2, "Automation retired");
    expect(onLifecycleChanged).toHaveBeenCalledTimes(1);
    expect(await screen.findByText("revoked")).toBeVisible();
    prompt.mockRestore();
    confirm.mockRestore();
  });
});
