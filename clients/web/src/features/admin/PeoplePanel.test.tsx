import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import { StepUpProvider } from "../../app/step-up";
import type { AccountSession, Invitation, User } from "../../types";
import { PeoplePanel } from "./PeoplePanel";

const sessionApi = vi.hoisted(() => ({ stepUp: vi.fn() }));
vi.mock("../../app/session", () => ({
  useSession: () => ({
    api: sessionApi,
    session: { tenant: { id: "tenant-1", name: "Acme", slug: "acme", status: "active" } }
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

  it("turns a one-time invitation token into a copy-ready fragment URL", async () => {
    const invitations = vi.fn().mockResolvedValue([]);
    const createInvitation = vi.fn().mockResolvedValue({ invitation, invitationToken: "one-time-secret" });
    const user = userEvent.setup();
    renderPanel({ invitations, createInvitation });

    await user.type(screen.getByLabelText("Email"), "new.member@example.test");
    await user.click(screen.getByRole("button", { name: "Create invitation" }));

    expect(createInvitation).toHaveBeenCalledWith({ email: "new.member@example.test", role: "member" });
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
    const user = userEvent.setup();
    renderPanel({ invitations, updateAdminUser });

    const roleSelect = screen.getByLabelText("Role for Taylor Member");
    await user.selectOptions(roleSelect, "admin");
    expect(updateAdminUser).not.toHaveBeenCalled();
    expect(screen.getByRole("alertdialog", { name: "Apply this access change?" })).toHaveTextContent("Member to Administrator");

    await user.type(screen.getByLabelText("Audit reason"), "Promotion approved by workspace owner");
    await user.click(screen.getByRole("button", { name: "Confirm change" }));

    await waitFor(() => expect(updateAdminUser).toHaveBeenCalledWith("user-1", {
      role: "admin",
      reason: "Promotion approved by workspace owner",
      version: 4
    }));
    expect(await screen.findByRole("status")).toHaveTextContent("Taylor Member updated");
    expect(screen.queryByRole("alertdialog", { name: "Apply this access change?" })).not.toBeInTheDocument();
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

    await user.click(screen.getByRole("button", { name: "Manage" }));
    const trigger = await screen.findByRole("button", { name: "Revoke" });
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
});
