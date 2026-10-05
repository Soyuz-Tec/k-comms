import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { MemberWorkspace, Session } from "../../types";
import { ApiError } from "../../api/errors";
import { useMemberWorkspace } from "./useMemberWorkspace";
import { SetupGuide } from "./SetupGuide";
import { PrivateContacts } from "./PrivateContacts";
import { workspaceFixture } from "./memberWorkspace.testSupport";

const grace = { id: "11111111-1111-4111-8111-111111111111", display_name: "Grace Hopper" };
const alan = { id: "22222222-2222-4222-8222-222222222222", display_name: "Alan Turing" };
const group = { id: "33333333-3333-4333-8333-333333333333", name: "Planning", member_ids: [grace.id] };
const harness = vi.hoisted(() => ({
  session: null as Session | null,
  api: { memberWorkspace: vi.fn(), updateMemberWorkspace: vi.fn(), updateOnboarding: vi.fn() },
  onStart: vi.fn()
}));
vi.mock("../../app/session", () => ({ useSession: () => ({ api: harness.api, session: harness.session }) }));
function session(id = "first"): Session {
  return { access_token: `synthetic-${id}`, refresh_token: "synthetic-refresh", token_type: "Bearer", expires_in: 900,
    tenant: { id: `tenant-${id}`, name: "Synthetic workspace", slug: id, status: "active" },
    user: { id: `user-${id}`, tenant_id: `tenant-${id}`, display_name: "Member", role: "member", status: "active" },
    device: { id: `device-${id}`, user_id: `user-${id}`, name: "Browser", platform: "web" } };
}
function View({ section = "groups" }: { section?: "groups" | "contacts" }) {
  const controller = useMemberWorkspace();
  return <><SetupGuide controller={controller} settings /><PrivateContacts key={controller.identity} controller={controller}
    section={section} query="" onStart={harness.onStart} busyAction={false} audioEnabled videoEnabled /></>;
}
function setup(section: "groups" | "contacts" = "groups") {
  return render(<MemoryRouter><View section={section} /></MemoryRouter>);
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((complete) => { resolve = complete; });
  return { promise, resolve };
}

describe("synchronized private workspace", () => {
  beforeEach(() => {
    harness.session = session();
    harness.api.memberWorkspace.mockReset().mockResolvedValue(workspaceFixture({ contacts: [grace, alan], groups: [group] }));
    harness.api.updateMemberWorkspace.mockReset();
    harness.api.updateOnboarding.mockReset();
    harness.onStart.mockReset();
  });

  it("keeps a pending onboarding action through409 and retries against the refreshed version", async () => {
    const user = userEvent.setup();
    harness.api.memberWorkspace.mockResolvedValueOnce(workspaceFixture()).mockResolvedValue(workspaceFixture({ version: 4 }));
    harness.api.updateOnboarding.mockRejectedValueOnce(new ApiError(409, "stale_version", "Changed"))
      .mockResolvedValueOnce(workspaceFixture({ version: 5, onboarding: { dismissed_at: "2026-10-05T01:00:00Z", profile_reviewed_at: null, active_devices: 1, has_teammates: true } }));
    setup();
    await user.click(await screen.findByRole("button", { name: "Hide for now" }));
    await user.click(await screen.findByRole("button", { name: "Retry setup change" }));
    await screen.findByRole("button", { name: "Resume setup" });
    expect(harness.api.updateOnboarding.mock.calls).toEqual([[{ version: 1, action: "dismiss" }], [{ version: 4, action: "dismiss" }]]);
  });

  it("never requests media or notification permission when reading or resuming the guide", async () => {
    const user = userEvent.setup();
    const media = vi.fn();
    const permission = vi.fn();
    const originalMedia = Object.getOwnPropertyDescriptor(navigator, "mediaDevices");
    const originalNotification = Object.getOwnPropertyDescriptor(window, "Notification");
    Object.defineProperty(navigator, "mediaDevices", { configurable: true, value: { getUserMedia: media } });
    Object.defineProperty(window, "Notification", { configurable: true, value: { requestPermission: permission } });
    try {
      harness.api.memberWorkspace.mockResolvedValue(workspaceFixture({ onboarding: { dismissed_at: "2026-10-05T00:00:00Z", profile_reviewed_at: null, active_devices: 1, has_teammates: true } }));
      harness.api.updateOnboarding.mockResolvedValue(workspaceFixture({ version: 2 }));
      setup();
      await user.click(await screen.findByRole("button", { name: "Resume setup" }));
      await screen.findByRole("link", { name: "Review profile" });
      expect(media).not.toHaveBeenCalled();
      expect(permission).not.toHaveBeenCalled();
      expect(screen.getByText("Save your profile to record review")).toBeVisible();
    } finally {
      if (originalMedia) Object.defineProperty(navigator, "mediaDevices", originalMedia); else Reflect.deleteProperty(navigator, "mediaDevices");
      if (originalNotification) Object.defineProperty(window, "Notification", originalNotification); else Reflect.deleteProperty(window, "Notification");
    }
  });

  it("keeps unsaved group text/members after409 and preserves another browser's unrelated group", async () => {
    const user = userEvent.setup();
    const external = { id: "44444444-4444-4444-8444-444444444444", name: "Other browser", member_ids: [alan.id] };
    harness.api.memberWorkspace.mockResolvedValueOnce(workspaceFixture({ contacts: [grace, alan], groups: [group] }))
      .mockResolvedValue(workspaceFixture({ version: 4, contacts: [grace, alan], groups: [group, external] }));
    harness.api.updateMemberWorkspace.mockRejectedValueOnce(new ApiError(409, "stale_version", "Changed"))
      .mockResolvedValueOnce(workspaceFixture({ version: 5, contacts: [grace, alan], groups: [{ ...group, name: "My pending name", member_ids: [grace.id, alan.id] }, external] }));
    setup();
    await user.click(await screen.findByRole("button", { name: "Edit Planning" }));
    const editor = screen.getByRole("form", { name: "Edit private contact group" });
    await user.clear(within(editor).getByLabelText("Group name"));
    await user.type(within(editor).getByLabelText("Group name"), "My pending name");
    await user.click(within(editor).getByRole("checkbox", { name: "Alan Turing" }));
    await user.click(within(editor).getByRole("button", { name: "Save contact group" }));
    await within(screen.getByRole("region", { name: "Private contact groups" })).findByText("Your workspace changed elsewhere. Your pending changes are kept; review and retry.");
    expect(within(editor).getByLabelText("Group name")).toHaveValue("My pending name");
    expect(within(editor).getByRole("checkbox", { name: "Alan Turing" })).toBeChecked();
    await user.click(within(editor).getByRole("button", { name: "Save contact group" }));
    expect(harness.api.updateMemberWorkspace.mock.calls[1]?.[0]).toEqual({ version: 4, contact_ids: [grace.id, alan.id], groups: [external, { ...group, name: "My pending name", member_ids: [grace.id, alan.id] }] });
  });

  it("clears loaded names and unsaved group input after an actual write denial", async () => {
    const user = userEvent.setup();
    harness.api.updateMemberWorkspace.mockRejectedValue(new ApiError(403, "forbidden", "Access revoked"));
    setup();
    await user.click(await screen.findByRole("button", { name: "Edit Planning" }));
    await user.type(screen.getByLabelText("Group name"), " private pending text");
    await user.click(screen.getByRole("button", { name: "Save contact group" }));
    await screen.findByText("Private contacts are unavailable. Sign in again to continue.");
    expect(screen.queryByDisplayValue("Planning private pending text")).not.toBeInTheDocument();
    expect(screen.queryByText("Grace Hopper")).not.toBeInTheDocument();
    expect(screen.queryByText("Planning")).not.toBeInTheDocument();
  });

  it("rejects a delayed prior-session read after the next identity has loaded", async () => {
    const old = deferred<MemberWorkspace>();
    harness.api.memberWorkspace.mockReturnValueOnce(old.promise).mockResolvedValue(workspaceFixture({ contacts: [alan] }));
    const view = setup("contacts");
    harness.session = session("second");
    view.rerender(<MemoryRouter><View section="contacts" /></MemoryRouter>);
    await screen.findByText("Alan Turing");
    await act(async () => old.resolve(workspaceFixture({ contacts: [grace], groups: [group] })));
    expect(screen.queryByText("Grace Hopper")).not.toBeInTheDocument();
    expect(screen.getByText("Alan Turing")).toBeVisible();
  });

  it("ignores a prior identity's successful write after another identity has loaded", async () => {
    const user = userEvent.setup();
    const old = deferred<MemberWorkspace>();
    harness.api.memberWorkspace.mockResolvedValueOnce(workspaceFixture({ contacts: [grace], groups: [group] }))
      .mockResolvedValue(workspaceFixture({ contacts: [alan] }));
    harness.api.updateMemberWorkspace.mockReturnValue(old.promise);
    const view = setup();
    await user.click(await screen.findByRole("button", { name: "Edit Planning" }));
    await user.click(screen.getByRole("button", { name: "Save contact group" }));
    expect(harness.api.updateMemberWorkspace).toHaveBeenCalledTimes(1);
    harness.session = session("second");
    view.rerender(<MemoryRouter><View section="contacts" /></MemoryRouter>);
    await screen.findByText("Alan Turing");
    await act(async () => old.resolve(workspaceFixture({ version: 2, contacts: [grace], groups: [group] })));
    expect(screen.queryByText("Grace Hopper")).not.toBeInTheDocument();
    expect(screen.queryByText("Planning")).not.toBeInTheDocument();
    expect(screen.getByText("Alan Turing")).toBeVisible();
  });

  it("clears existing private state when focus revalidation is denied", async () => {
    setup("contacts");
    await screen.findByText("Grace Hopper");
    harness.api.memberWorkspace.mockRejectedValue(new ApiError(403, "forbidden", "Access revoked"));
    fireEvent.focus(window);
    await screen.findByText("Private contacts are unavailable. Sign in again to continue.");
    expect(screen.queryByText("Grace Hopper")).not.toBeInTheDocument();
  });

  it("removes a private contact/group reference without changing conversation authority", async () => {
    const user = userEvent.setup();
    harness.api.updateMemberWorkspace.mockResolvedValue(workspaceFixture({ version: 2, contacts: [alan], groups: [{ ...group, member_ids: [] }] }));
    setup("contacts");
    await user.click(await screen.findByRole("button", { name: "Remove Grace Hopper from contacts" }));
    await waitFor(() => expect(screen.queryByText("Grace Hopper")).not.toBeInTheDocument());
    expect(harness.api.updateMemberWorkspace).toHaveBeenCalledWith({ version: 1, contact_ids: [alan.id], groups: [{ ...group, member_ids: [] }] });
    expect(harness.onStart).not.toHaveBeenCalled();
  });

  it("defers focus refresh until a pending write resolves, preserving its returned version", async () => {
    const user = userEvent.setup();
    const pending = deferred<MemberWorkspace>();
    harness.api.updateOnboarding.mockReturnValue(pending.promise);
    setup();
    await user.click(await screen.findByRole("button", { name: "Hide for now" }));
    fireEvent.focus(window);
    expect(harness.api.memberWorkspace).toHaveBeenCalledTimes(1);
    harness.api.memberWorkspace.mockResolvedValue(workspaceFixture({ version: 2, onboarding: { dismissed_at: "2026-10-05T01:00:00Z", profile_reviewed_at: null, active_devices: 1, has_teammates: true } }));
    await act(async () => pending.resolve(workspaceFixture({ version: 2, onboarding: { dismissed_at: "2026-10-05T01:00:00Z", profile_reviewed_at: null, active_devices: 1, has_teammates: true } })));
    await screen.findByRole("button", { name: "Resume setup" });
    expect(harness.api.memberWorkspace).toHaveBeenCalledTimes(2);
  });
});
