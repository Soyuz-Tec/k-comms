import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import { StepUpProvider } from "../../app/step-up";
import type { AccountSession, Invitation, Session, User } from "../../types";
import { PeoplePanel } from "./PeoplePanel";

const sessionApi = vi.hoisted(() => ({ stepUp: vi.fn() }));
vi.mock("../../app/session", () => ({
  useSession: () => ({
    api: sessionApi,
    session: {
      access_token: "owner-access", refresh_token: "owner-refresh", token_type: "Bearer", expires_in: 900,
      tenant: { id: "tenant-1", name: "Acme", slug: "acme", status: "active" },
      user: { id: "owner-1", tenant_id: "tenant-1", display_name: "Workspace Owner", email: "owner@example.test", role: "owner", status: "active", version: 1, account_type: "human", access_scope: "workspace" },
      device: { id: "owner-device", user_id: "owner-1", name: "Browser", platform: "web", last_seen_at: "2026-07-14T12:00:00Z" }
    } satisfies Session
  })
}));

const managedUser: User = {
  id: "user-1",
  tenant_id: "tenant-1",
  display_name: "Taylor Member",
  email: "taylor@example.test",
  role: "member",
  status: "active",
  version: 4
};

const invitation: Invitation = {
  id: "invite-1",
  email: "new.member@example.test",
  role: "member",
  status: "pending",
  invited_by_user_id: "owner-1",
  expires_at: "2026-07-21T12:00:00Z",
  version: 1,
  inserted_at: "2026-07-14T12:00:00Z"
};

const accountSession: AccountSession = {
  id: "session-12345678",
  user_id: managedUser.id,
  device_id: "device-1",
  expires_at: "2026-07-21T12:00:00Z",
  last_used_at: "2026-07-14T12:00:00Z",
  inserted_at: "2026-07-14T11:00:00Z",
  revoked_at: null
};

function renderPanel(api: Partial<ApiClient>, users: User[] = [managedUser]) {
  return render(
    <StepUpProvider>
      <PeoplePanel api={api as ApiClient} actorRole="owner" users={users} setUsers={vi.fn()} />
    </StepUpProvider>
  );
}

describe("PeoplePanel", () => {
  beforeEach(() => {
    sessionApi.stepUp.mockReset().mockResolvedValue({ step_up_at: "2026-07-14T12:00:00Z" });
  });

  it("gives invitation-load errors a descriptive dismiss control", async () => {
    const user = userEvent.setup();
    renderPanel({ invitations: vi.fn().mockRejectedValue(new Error("Invitations unavailable")) });

    const dismiss = await screen.findByRole("button", { name: "Dismiss people error" });
    expect(screen.getByRole("alert")).toHaveTextContent("Invitations unavailable");
    await user.click(dismiss);
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("turns a one-time invitation token into a copy-ready fragment URL", async () => {
    const invitations = vi.fn().mockResolvedValue([]);
    const createInvitation = vi.fn().mockResolvedValue({ invitation, invitationToken: "one-time-secret" });
    const user = userEvent.setup();
    renderPanel({ invitations, createInvitation });

    await user.type(screen.getByLabelText("Email"), "new.member@example.test");
    await user.click(screen.getByRole("button", { name: "Create invitation" }));

    expect(createInvitation).toHaveBeenCalledWith({ email: "new.member@example.test", role: "member" });
    expect(screen.getByRole("region", { name: "Invitations" })).toHaveAttribute("id", "admin-invitations");
    const link = await screen.findByText(/#invitation_token=one-time-secret/);
    expect(link).toHaveTextContent(`${window.location.origin}/app/#invitation_token=one-time-secret&tenant_slug=acme`);
    expect(link).not.toHaveTextContent("?invitation_token=");
    expect(screen.getByRole("button", { name: "Create invitation" })).toBeDisabled();
    expect(screen.getByText(/contains a one-time secret/i)).toBeVisible();
  });

  it("requires an explicit review and audit reason before changing access", async () => {
    const invitations = vi.fn().mockResolvedValue([]);
    const updatedUser = { ...managedUser, role: "admin" as const, version: 5 };
    const updateAdminUser = vi.fn().mockResolvedValue(updatedUser);
    const previewAdminUserRole = vi.fn().mockResolvedValue({
      target_id: managedUser.id,
      current_role: "member",
      requested_role: "admin",
      current_version: 4,
      target_status: "active",
      target_access_scope: "workspace",
      role_policy_allows: true,
      blockers: [],
      added: [{ capability: "manage_user_lifecycle", scope: "tenant", conditions: ["active_tenant", "active_identity", "current_session", "workspace_access", "recent_step_up"] }],
      removed: [],
      advisory: true,
      scope: "tenant",
      governance_review_required: true
    });
    const user = userEvent.setup();
    renderPanel({ invitations, updateAdminUser, previewAdminUserRole });

    const roleSelect = screen.getByLabelText("Role for Taylor Member");
    await user.selectOptions(roleSelect, "admin");
    expect(updateAdminUser).not.toHaveBeenCalled();
    expect(screen.getByRole("alertdialog", { name: "Review this role change" })).toHaveTextContent("Member to Administrator");
    expect(previewAdminUserRole).toHaveBeenCalledWith("user-1", { role: "admin", version: 4 });
    expect(await screen.findByText("Change account roles and status")).toBeVisible();

    await user.type(screen.getByLabelText("Audit reason"), "Promotion approved by workspace owner");
    await user.click(screen.getByRole("button", { name: "Confirm change" }));

    await waitFor(() => expect(updateAdminUser).toHaveBeenCalledWith("user-1", {
      role: "admin",
      reason: "Promotion approved by workspace owner",
      version: 4
    }));
    expect(await screen.findByRole("status")).toHaveTextContent("Taylor Member updated");
    expect(screen.queryByRole("alertdialog", { name: "Review this role change" })).not.toBeInTheDocument();
    await waitFor(() => expect(roleSelect).toHaveFocus());
  });

  it("reviews invitation revocation, requires a reason, and restores trigger focus on cancel", async () => {
    const invitations = vi.fn().mockResolvedValue([invitation]);
    const revokedInvitation = { ...invitation, status: "revoked" as const, revoked_at: "2026-07-14T13:00:00Z", version: 2 };
    const revokeInvitation = vi.fn().mockResolvedValue(revokedInvitation);
    const user = userEvent.setup();
    renderPanel({ invitations, revokeInvitation });

    const trigger = await screen.findByRole("button", { name: "Revoke" });
    await user.click(trigger);
    expect(screen.getByRole("alertdialog", { name: "Revoke this invitation?" })).toHaveTextContent("new.member@example.test");
    await waitFor(() => expect(screen.getByRole("button", { name: "Cancel" })).toHaveFocus());
    await user.keyboard("{Escape}");
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
    await waitFor(() => expect(trigger).toHaveFocus());

    await user.click(trigger);
    await waitFor(() => expect(screen.getByRole("button", { name: "Cancel" })).toHaveFocus());
    await user.type(screen.getByLabelText("Audit reason"), "Recipient no longer needs access");
    await user.click(screen.getByRole("button", { name: "Revoke invitation" }));

    await waitFor(() => expect(revokeInvitation).toHaveBeenCalledWith("invite-1", 1, "Recipient no longer needs access"));
    expect(await screen.findByRole("status")).toHaveTextContent("Invitation for new.member@example.test revoked");
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
  });

  it("reviews session revocation and passes its audited reason through step-up", async () => {
    const invitations = vi.fn().mockResolvedValue([]);
    const adminUserSessions = vi.fn().mockResolvedValue([accountSession]);
    const adminRevokeSession = vi.fn().mockResolvedValue(undefined);
    const user = userEvent.setup();
    renderPanel({ invitations, adminUserSessions, adminRevokeSession });

    await user.click(
      screen.getByRole("button", {
        name: "Manage sessions for Taylor Member"
      })
    );
    const trigger = await screen.findByRole("button", {
      name: "Revoke session session- for Taylor Member"
    });
    await user.click(trigger);
    expect(screen.getByRole("alertdialog", { name: "Revoke this session?" })).toHaveTextContent("session-");
    expect(adminRevokeSession).not.toHaveBeenCalled();

    await user.type(screen.getByLabelText("Audit reason"), "Device reported lost by user");
    await user.click(screen.getByRole("button", { name: "Revoke session" }));

    await waitFor(() => expect(adminRevokeSession).toHaveBeenCalledWith("user-1", "session-12345678", "Device reported lost by user"));
    expect(await screen.findByRole("status")).toHaveTextContent("Session for Taylor Member revoked");
    expect(screen.getByText("Revoked")).toBeVisible();
  });

  it("filters people and invitations without mixing the two result sets", async () => {
    const invitations = vi.fn().mockResolvedValue([invitation]);
    renderPanel({ invitations }, [managedUser, { ...managedUser, id: "user-2", display_name: "Morgan Moderator", email: "morgan@example.test", role: "moderator" }]);

    expect(await screen.findByText("new.member@example.test")).toBeVisible();
    await userEvent.type(screen.getByLabelText("Search people"), "Morgan");
    expect(screen.getByText("Morgan Moderator")).toBeVisible();
    expect(screen.queryByText("Taylor Member")).not.toBeInTheDocument();

    await userEvent.type(screen.getByLabelText("Search invitations"), "revoked");
    expect(screen.getByText("No invitations match this search.")).toBeVisible();
    expect(screen.getByText("Morgan Moderator")).toBeVisible();
  });

  it("keeps identity and protected controls in the same semantic person group", async () => {
    const adminUserSessions = vi.fn().mockResolvedValue([accountSession]);
    const user = userEvent.setup();
    renderPanel({ invitations: vi.fn().mockResolvedValue([]), adminUserSessions });

    const table = screen.getByRole("region", { name: "Workspace people" });
    const personGroup = within(table).getByText("Taylor Member").closest("tbody")!;
    expect(within(personGroup).getByRole("combobox", { name: "Role for Taylor Member" })).toHaveValue("member");
    expect(within(personGroup).getByRole("combobox", { name: "Status for Taylor Member" })).toHaveValue("active");
    const manage = within(personGroup).getByRole("button", { name: "Manage sessions for Taylor Member" });
    expect(manage).toHaveAttribute("aria-expanded", "false");
    await user.click(manage);
    const sessions = await within(personGroup).findByRole("list", { name: "Sessions for Taylor Member" });
    expect(manage).toHaveAttribute("aria-controls", sessions.id);
    expect(manage).toHaveAttribute("aria-expanded", "true");
    await user.click(manage);
    expect(within(personGroup).queryByRole("list", { name: "Sessions for Taylor Member" })).not.toBeInTheDocument();
    expect(manage).toHaveAttribute("aria-expanded", "false");
  });

  it("does not expose access edits or login sessions for service identities", async () => {
    const serviceUser = { ...managedUser, account_type: "service" as const };
    renderPanel({ invitations: vi.fn().mockResolvedValue([]) }, [serviceUser]);

    expect(screen.getByText("Non-login service identity")).toBeVisible();
    expect(screen.getByText("Service credential")).toBeVisible();
    expect(screen.queryByRole("combobox", { name: "Role for Taylor Member" })).not.toBeInTheDocument();
    expect(screen.queryByRole("combobox", { name: "Status for Taylor Member" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Manage sessions for Taylor Member" })).not.toBeInTheDocument();
  });

  it("combines role and status filters, reports counts, and sorts without mutating the source list", async () => {
    const users: User[] = [
      managedUser,
      { ...managedUser, id: "user-2", display_name: "Morgan Moderator", role: "moderator", status: "suspended" },
      { ...managedUser, id: "user-3", display_name: "Alex Administrator", role: "admin" }
    ];
    const user = userEvent.setup();
    renderPanel({ invitations: vi.fn().mockResolvedValue([]) }, users);
    expect(screen.getByText("3 accounts")).toBeVisible();
    expect(screen.getByText("Showing 3 of 3 accounts · 2 active in this workspace")).toBeVisible();
    const table = screen.getByRole("region", { name: "Workspace people" });
    const names = () => Array.from(table.querySelectorAll(".people-identity strong")).map((node) => node.textContent?.trim());
    expect(names()).toEqual(["Alex Administrator", "Morgan Moderator", "Taylor Member"]);
    await user.selectOptions(screen.getByLabelText("Sort people"), "name-desc");
    expect(names()).toEqual(["Taylor Member", "Morgan Moderator", "Alex Administrator"]);
    await user.selectOptions(screen.getByLabelText("Filter by role"), "moderator");
    await user.selectOptions(screen.getByLabelText("Filter by status"), "suspended");
    expect(names()).toEqual(["Morgan Moderator"]);
    expect(screen.getByText("Showing 1 of 3 accounts · 2 active in this workspace")).toBeVisible();
    await user.selectOptions(screen.getByLabelText("Filter by status"), "active");
    expect(screen.getByText("No people match these filters.")).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Clear filters" }));
    expect(names()).toEqual(["Taylor Member", "Morgan Moderator", "Alex Administrator"]);
    expect(users.map((record) => record.id)).toEqual(["user-1", "user-2", "user-3"]);
    expect(screen.queryByText("Live API")).not.toBeInTheDocument();
  });

  it("expands existing person information without loading privileged sessions", async () => {
    const adminUserSessions = vi.fn();
    const user = userEvent.setup();
    renderPanel({ invitations: vi.fn().mockResolvedValue([]), adminUserSessions });
    const view = screen.getByRole("button", { name: "View details for Taylor Member" });
    expect(view).toHaveAttribute("aria-expanded", "false");
    await user.click(view);
    const details = screen.getByRole("region", { name: "Details for Taylor Member" });
    expect(view).toHaveAttribute("aria-controls", details.id);
    expect(within(details).getByText("Human")).toBeVisible();
    expect(within(details).getByText("taylor@example.test")).toBeVisible();
    expect(within(details).getByText("user-1")).toBeVisible();
    expect(within(details).getByText("4")).toBeVisible();
    expect(adminUserSessions).not.toHaveBeenCalled();
    await user.click(screen.getByRole("button", { name: "Hide details for Taylor Member" }));
    expect(screen.queryByRole("region", { name: "Details for Taylor Member" })).not.toBeInTheDocument();
    expect(view).toHaveAttribute("aria-expanded", "false");
  });

  it("shows provided session and device IDs with lifecycle dates instead of guessed device names", async () => {
    const adminUserSessions = vi.fn().mockResolvedValue([accountSession]);
    const user = userEvent.setup();
    renderPanel({ invitations: vi.fn().mockResolvedValue([invitation]), adminUserSessions });
    expect(await screen.findByText("1 pending")).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Manage sessions for Taylor Member" }));
    const sessions = await screen.findByRole("list", { name: "Sessions for Taylor Member" });
    expect(within(sessions).getByText(/Created .*Expires/)).toBeVisible();
    await user.click(within(sessions).getByText("Session identifiers"));
    expect(within(sessions).getByText("session-12345678")).toBeVisible();
    expect(within(sessions).getByText("device-1")).toBeVisible();
    expect(adminUserSessions).toHaveBeenCalledWith("user-1");
    expect(within(sessions).queryByText(/Windows|Chrome|Web browser/)).not.toBeInTheDocument();
  });
});
