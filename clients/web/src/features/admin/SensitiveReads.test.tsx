import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "../../api";
import type { ApiClient } from "../../api";
import { StepUpProvider } from "../../app/step-up";
import type { AccountSession, AuditEvent, User } from "../../types";
import { AuditPanel } from "./AuditPanel";
import { GovernancePanel } from "./GovernancePanel";
import { PeoplePanel } from "./PeoplePanel";
import { ServiceAccountsPanel } from "./ServiceAccountsPanel";

const stepUp = vi.hoisted(() => vi.fn());
vi.mock("../../app/session", () => ({ useSession: () => ({ api: { stepUp } }) }));

const stepUpRequired = () => new ApiError(428, "step_up_required", "Recent password verification is required");

async function completeStepUp(user: ReturnType<typeof userEvent.setup>) {
  expect(await screen.findByRole("dialog", { name: "Confirm it is you" })).toBeVisible();
  await user.type(screen.getByLabelText("Current password"), "correct horse battery staple");
  await user.click(screen.getByRole("button", { name: "Continue" }));
}

describe("sensitive administration reads", () => {
  beforeEach(() => {
    stepUp.mockReset().mockResolvedValue({ step_up_at: "2026-07-12T10:00:00Z" });
  });

  it("cold-loads audit evidence after an expired step-up is renewed", async () => {
    const event: AuditEvent = {
      id: "audit-1",
      actor_user_id: "user-1",
      action: "tenant.settings.viewed",
      resource_type: "tenant",
      resource_id: "tenant-1",
      metadata: {},
      request_id: "request-1",
      inserted_at: "2026-07-12T10:00:00Z"
    };
    const auditEvents = vi.fn().mockRejectedValueOnce(stepUpRequired()).mockResolvedValueOnce([event]);
    const user = userEvent.setup();

    render(<StepUpProvider><AuditPanel api={{ auditEvents } as unknown as ApiClient} users={[]} /></StepUpProvider>);
    await completeStepUp(user);

    expect(stepUp).toHaveBeenCalledWith("correct horse battery staple");
    expect(await screen.findByText("tenant.settings.viewed")).toBeVisible();
    expect(auditEvents).toHaveBeenCalledTimes(2);
  });

  it("cold-loads all governance lists after step-up instead of leaving the panel failed", async () => {
    const retentionPolicies = vi.fn().mockRejectedValueOnce(stepUpRequired()).mockResolvedValueOnce([]);
    const legalHolds = vi.fn().mockResolvedValue([]);
    const deletionRequests = vi.fn().mockResolvedValue([]);
    const user = userEvent.setup();
    const api = { retentionPolicies, legalHolds, deletionRequests } as unknown as ApiClient;

    render(<StepUpProvider><GovernancePanel api={api} users={[]} conversations={[]} /></StepUpProvider>);
    await completeStepUp(user);

    await waitFor(() => expect(retentionPolicies).toHaveBeenCalledTimes(2));
    expect(legalHolds).toHaveBeenCalledTimes(2);
    expect(deletionRequests).toHaveBeenCalledTimes(2);
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("retries protected user-session reads through step-up", async () => {
    const managedUser: User = {
      id: "user-1",
      tenant_id: "tenant-1",
      display_name: "Taylor Admin",
      email: "taylor@example.test",
      role: "member",
      status: "active",
      version: 1
    };
    const session: AccountSession = {
      id: "session-1",
      user_id: managedUser.id,
      device_id: "device-1",
      expires_at: "2026-07-13T10:00:00Z",
      last_used_at: "2026-07-12T10:00:00Z",
      inserted_at: "2026-07-12T09:00:00Z",
      revoked_at: null
    };
    const adminUserSessions = vi.fn().mockRejectedValueOnce(stepUpRequired()).mockResolvedValueOnce([session]);
    const user = userEvent.setup();

    render(<StepUpProvider><PeoplePanel api={{ adminUserSessions } as unknown as ApiClient} actorRole="security_admin" users={[managedUser]} setUsers={vi.fn()} /></StepUpProvider>);
    await user.click(screen.getByRole("button", { name: "Manage" }));
    await completeStepUp(user);

    expect(await screen.findByText("Session session-")).toBeVisible();
    expect(adminUserSessions).toHaveBeenCalledTimes(2);
  });

  it("cold-loads the service credential inventory only after step-up", async () => {
    const serviceAccounts = vi.fn().mockRejectedValueOnce(stepUpRequired()).mockResolvedValueOnce([]);
    const user = userEvent.setup();

    render(<StepUpProvider><ServiceAccountsPanel api={{ serviceAccounts } as unknown as ApiClient} /></StepUpProvider>);
    await completeStepUp(user);

    expect(await screen.findByText("No service accounts configured.")).toBeVisible();
    expect(serviceAccounts).toHaveBeenCalledTimes(2);
  });
});
