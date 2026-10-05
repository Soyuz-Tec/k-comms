import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { StrictMode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "../../api";
import { StepUpProvider } from "../../app/step-up";
import type { User } from "../../types";
import type { UserRoleChangePreview } from "../../types/rolePermissions";
import { RoleChangeDialog } from "./RoleChangeDialog";

const sessionApi = vi.hoisted(() => ({ stepUp: vi.fn() }));
const actor = vi.hoisted(() => ({ accessToken: "test-owner-session", role: "owner" }));
vi.mock("../../app/session", () => ({ useSession: () => ({ api: sessionApi, session: { tenant: { id: "tenant-1" }, user: { id: "actor-1", role: actor.role, status: "active", version: 1 }, device: { id: "actor-device" }, access_token: actor.accessToken } }) }));

const person: User = { id: "person-1", tenant_id: "tenant-1", display_name: "Taylor", email: "taylor@example.test", role: "admin", status: "active", version: 4 };

function preview(overrides: Partial<UserRoleChangePreview> = {}): UserRoleChangePreview {
  return {
    target_id: person.id,
    current_role: "admin",
    requested_role: "security_admin",
    current_version: 4,
    target_status: "active",
    target_access_scope: "workspace",
    role_policy_allows: true,
    blockers: [],
    added: [{ capability: "manage_sessions", scope: "tenant", conditions: ["active_tenant", "active_identity", "current_session", "workspace_access", "recent_step_up"] }],
    removed: [{ capability: "manage_invitations", scope: "tenant", conditions: ["active_tenant", "active_identity", "current_session", "workspace_access", "recent_step_up"] }],
    advisory: true,
    scope: "tenant",
    governance_review_required: true,
    ...overrides
  };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

function setup(previewAdminUserRole = vi.fn().mockResolvedValue(preview()), user = person) {
  const onConfirm = vi.fn();
  const onCancel = vi.fn();
  const onReviewAgain = vi.fn();
  const api = { previewAdminUserRole };
  const props = { api, user, identifier: user.display_name, requestedRole: "security_admin" as const, busy: false, error: null, onConfirm, onCancel, onReviewAgain };
  const view = render(<StepUpProvider><RoleChangeDialog {...props} /></StepUpProvider>);
  return { ...view, props, onConfirm, onCancel, onReviewAgain, previewAdminUserRole };
}

describe("role change review", () => {
  beforeEach(() => {
    sessionApi.stepUp.mockReset().mockResolvedValue({ step_up_at: "2026-10-05T01:00:00Z" });
    actor.accessToken = "test-owner-session";
    actor.role = "owner";
  });

  it("waits for current permission facts and requires an explicit audited confirmation", async () => {
    const pending = deferred<UserRoleChangePreview>();
    const { previewAdminUserRole, onConfirm, onCancel } = setup(vi.fn().mockReturnValue(pending.promise));
    expect(screen.getByRole("status")).toHaveTextContent("Loading current permissions");
    expect(screen.getByRole("button", { name: "Confirm change" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Cancel" })).toBeEnabled();
    expect(onConfirm).not.toHaveBeenCalled();
    await act(async () => { pending.resolve(preview()); });
    const added = screen.getByRole("region", { name: "Permissions added" });
    expect(within(added).getByText("Manage people's sign-in sessions")).toBeVisible();
    expect(within(added).getByText(/recent privileged verification/)).toBeVisible();
    expect(screen.getByRole("region", { name: "Permissions removed" })).toHaveTextContent("Manage workspace invitations");
    expect(screen.getByRole("note")).toHaveTextContent("checks run again when you confirm");
    expect(previewAdminUserRole).toHaveBeenCalledWith(person.id, { role: "security_admin", version: 4 });
    await userEvent.click(screen.getByRole("button", { name: "Confirm change" }));
    expect(screen.getByRole("alert")).toHaveTextContent("Enter a reason");
    expect(screen.getByLabelText("Audit reason")).toHaveFocus();
    expect(onConfirm).not.toHaveBeenCalled();
    await userEvent.type(screen.getByLabelText("Audit reason"), "  Security duties approved  ");
    await userEvent.click(screen.getByRole("button", { name: "Confirm change" }));
    expect(onConfirm).toHaveBeenCalledWith("Security duties approved");
    expect(onCancel).not.toHaveBeenCalled();
  });

  it.each([
    { blockers: ["last_owner_required" as const], role_policy_allows: true, text: "An active owner must remain" },
    { blockers: ["forbidden" as const], role_policy_allows: false, text: "This role change is not permitted" }
  ])("prevents confirmation when the server reports $text", async ({ blockers, role_policy_allows, text }) => {
    const { onConfirm } = setup(vi.fn().mockResolvedValue(preview({ blockers, role_policy_allows })));
    expect(await screen.findByRole("alert")).toHaveTextContent(text);
    await userEvent.type(screen.getByLabelText("Audit reason"), "Approved reason");
    expect(screen.getByRole("button", { name: "Confirm change" })).toBeDisabled();
    expect(onConfirm).not.toHaveBeenCalled();
  });

  it("rejects a preview for another account or record version", async () => {
    const { onConfirm } = setup(vi.fn().mockResolvedValue(preview({ target_id: "another-person", current_version: 5 })));
    expect(await screen.findByRole("alert")).toHaveTextContent("no longer matches the selected account");
    expect(screen.getByRole("button", { name: "Confirm change" })).toBeDisabled();
    expect(screen.queryByRole("region", { name: "Permissions added" })).not.toBeInTheDocument();
    expect(onConfirm).not.toHaveBeenCalled();
  });

  it("ignores a late preview after the account version changes", async () => {
    const old = deferred<UserRoleChangePreview>();
    const current = preview({ current_version: 5, added: [] });
    const api = vi.fn().mockReturnValueOnce(old.promise).mockResolvedValueOnce(current);
    const { props, rerender } = setup(api);
    rerender(<StepUpProvider><RoleChangeDialog {...props} user={{ ...person, version: 5 }} /></StepUpProvider>);
    expect(await screen.findByText("No workspace permissions are added.")).toBeVisible();
    await act(async () => { old.resolve(preview()); });
    expect(screen.getByText("No workspace permissions are added.")).toBeVisible();
    expect(screen.queryByText("Manage people's sign-in sessions")).not.toBeInTheDocument();
    expect(api).toHaveBeenLastCalledWith(person.id, { role: "security_admin", version: 5 });
  });

  it("requires a fresh people record after stale-version failure", async () => {
    const api = vi.fn().mockRejectedValue(new ApiError(409, "stale_version", "The account changed"));
    const { onConfirm } = setup(api);
    expect(await screen.findByRole("alert")).toHaveTextContent("reload the people list");
    expect(screen.getByRole("button", { name: "Confirm change" })).toBeDisabled();
    expect(screen.queryByRole("button", { name: "Review permissions again" })).not.toBeInTheDocument();
    expect(onConfirm).not.toHaveBeenCalled();
    expect(api).toHaveBeenCalledTimes(1);
  });

  it("invalidates the preview after an actual mutation denial and requires a fresh review", async () => {
    const next = deferred<UserRoleChangePreview>();
    const api = vi.fn().mockResolvedValueOnce(preview()).mockReturnValueOnce(next.promise);
    const { props, rerender, onConfirm, onReviewAgain } = setup(api);
    expect(await screen.findByText("Manage people's sign-in sessions")).toBeVisible();
    await userEvent.type(screen.getByLabelText("Audit reason"), "Approved reason");
    await userEvent.click(screen.getByRole("button", { name: "Confirm change" }));
    expect(onConfirm).toHaveBeenCalledTimes(1);

    rerender(<StepUpProvider><RoleChangeDialog {...props} error="The account changed. Reload before applying." /></StepUpProvider>);
    expect(screen.getByRole("button", { name: "Confirm change" })).toBeDisabled();
    expect(screen.queryByRole("region", { name: "Permissions added" })).not.toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Review permissions again" }));
    expect(onReviewAgain).toHaveBeenCalledTimes(1);
    rerender(<StepUpProvider><RoleChangeDialog {...props} /></StepUpProvider>);
    expect(screen.getByRole("button", { name: "Confirm change" })).toBeDisabled();
    expect(screen.queryByRole("region", { name: "Permissions added" })).not.toBeInTheDocument();
    await act(async () => { next.resolve(preview({ role_policy_allows: false, blockers: ["forbidden"] })); });
    expect(screen.getByRole("button", { name: "Confirm change" })).toBeDisabled();
    expect(onConfirm).toHaveBeenCalledTimes(1);
    expect(api).toHaveBeenCalledTimes(2);
  });

  it.each(["session", "role"])("discards the old preview and its late result when the actor %s changes", async (change) => {
    const old = deferred<UserRoleChangePreview>();
    const next = deferred<UserRoleChangePreview>();
    const api = vi.fn().mockReturnValueOnce(old.promise).mockReturnValueOnce(next.promise);
    const { props, rerender, onConfirm } = setup(api);
    if (change === "session") actor.accessToken = "test-replacement-session";
    else actor.role = "security_admin";
    rerender(<StepUpProvider><RoleChangeDialog {...props} /></StepUpProvider>);
    expect(screen.getByRole("button", { name: "Confirm change" })).toBeDisabled();
    await act(async () => { old.resolve(preview()); });
    expect(screen.queryByRole("region", { name: "Permissions added" })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Confirm change" })).toBeDisabled();
    await act(async () => { next.resolve(preview({ role_policy_allows: false, blockers: ["forbidden"] })); });
    expect(screen.getByRole("alert")).toHaveTextContent("not permitted");
    expect(screen.getByRole("button", { name: "Confirm change" })).toBeDisabled();
    expect(onConfirm).not.toHaveBeenCalled();
    expect(api).toHaveBeenCalledTimes(2);
  });

  it("disables previously reviewed permissions while a replacement actor session is being reviewed", async () => {
    const next = deferred<UserRoleChangePreview>();
    const api = vi.fn().mockResolvedValueOnce(preview()).mockReturnValueOnce(next.promise);
    const { props, rerender, onConfirm } = setup(api);
    expect(await screen.findByText("Manage people's sign-in sessions")).toBeVisible();
    expect(screen.getByRole("button", { name: "Confirm change" })).toBeEnabled();
    actor.accessToken = "test-replacement-session";
    rerender(<StepUpProvider><RoleChangeDialog {...props} /></StepUpProvider>);
    expect(screen.getByRole("button", { name: "Confirm change" })).toBeDisabled();
    expect(screen.queryByRole("region", { name: "Permissions added" })).not.toBeInTheDocument();
    await act(async () => { next.resolve(preview({ added: [] })); });
    expect(screen.getByText("No workspace permissions are added.")).toBeVisible();
    expect(screen.getByRole("button", { name: "Confirm change" })).toBeEnabled();
    expect(onConfirm).not.toHaveBeenCalled();
  });

  it("permits retrying a transient preview failure without applying a role", async () => {
    const api = vi.fn().mockRejectedValueOnce(new Error("Connection unavailable")).mockResolvedValueOnce(preview());
    const { onConfirm } = setup(api);
    expect(await screen.findByRole("alert")).toHaveTextContent("Connection unavailable");
    expect(screen.getByRole("button", { name: "Confirm change" })).toBeDisabled();
    await userEvent.click(screen.getByRole("button", { name: "Review permissions again" }));
    expect(await screen.findByText("Manage people's sign-in sessions")).toBeVisible();
    await waitFor(() => expect(screen.getByRole("button", { name: "Confirm change" })).toBeEnabled());
    expect(onConfirm).not.toHaveBeenCalled();
  });

  it("uses privileged verification for the preview without applying the role", async () => {
    const api = vi.fn().mockRejectedValueOnce(new ApiError(428, "step_up_required", "Verify again")).mockResolvedValueOnce(preview());
    const { onConfirm } = setup(api);
    const verification = await screen.findByRole("dialog", { name: "Confirm it is you" });
    await userEvent.type(within(verification).getByLabelText("Current password"), "current-password");
    await userEvent.click(within(verification).getByRole("button", { name: "Continue" }));
    expect(await screen.findByText("Manage people's sign-in sessions")).toBeVisible();
    expect(sessionApi.stepUp).toHaveBeenCalledWith("current-password", undefined);
    expect(api).toHaveBeenCalledTimes(2);
    expect(onConfirm).not.toHaveBeenCalled();
  });

  it("retries only the current StrictMode review after reverse-order duplicate 428 responses", async () => {
    const old = deferred<UserRoleChangePreview>(); const current = deferred<UserRoleChangePreview>();
    const api = { previewAdminUserRole: vi.fn().mockReturnValueOnce(old.promise).mockReturnValueOnce(current.promise).mockResolvedValue(preview()) };
    const onConfirm = vi.fn();
    render(<StrictMode><StepUpProvider><RoleChangeDialog api={api} user={person} identifier={person.display_name} requestedRole="security_admin"
      busy={false} error={null} onCancel={vi.fn()} onReviewAgain={vi.fn()} onConfirm={onConfirm} /></StepUpProvider></StrictMode>);
    expect(api.previewAdminUserRole).toHaveBeenCalledTimes(2);
    await act(async () => { current.reject(new ApiError(428, "step_up_required", "Verify again")); });
    await act(async () => { old.reject(new ApiError(428, "step_up_required", "Verify again")); });
    const verification = screen.getByRole("dialog", { name: "Confirm it is you" });
    await userEvent.type(within(verification).getByLabelText("Current password"), "current-password");
    await userEvent.click(within(verification).getByRole("button", { name: "Continue" }));
    expect(await screen.findByText("Manage people's sign-in sessions")).toBeVisible();
    expect(screen.getByRole("button", { name: "Confirm change" })).toBeEnabled();
    expect(screen.queryByText("Loading current permissions…")).not.toBeInTheDocument();
    expect(api.previewAdminUserRole).toHaveBeenCalledTimes(3); expect(sessionApi.stepUp).toHaveBeenCalledTimes(1);
    expect(onConfirm).not.toHaveBeenCalled();
  });

  it("explains limited scope and suspended-account conditions without implying enrollment", async () => {
    setup(vi.fn().mockResolvedValue(preview({ target_access_scope: "conversation_only", target_status: "suspended", added: [], removed: [], role_policy_allows: false, blockers: ["forbidden"] })));
    expect(await screen.findByText(/Changing its role does not enroll it/)).toBeVisible();
    expect(screen.getByText(/Permissions require an active account/)).toBeVisible();
    expect(screen.getByRole("button", { name: "Confirm change" })).toBeDisabled();
  });
});
