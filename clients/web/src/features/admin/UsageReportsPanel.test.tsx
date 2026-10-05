import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Session } from "../../types";
import type { UsageReport } from "../../types/usage";
import { ApiError } from "../../api/errors";
import { StepUpProvider } from "../../app/step-up";
import { UsageReportsPanel } from "./UsageReportsPanel";
import { usageFixture } from "./usageReports.testSupport";

const harness = vi.hoisted(() => ({ session: null as Session | null, api: { usageReport: vi.fn(), exportUsageReport: vi.fn(), stepUp: vi.fn() } }));
vi.mock("../../app/session", () => ({ useSession: () => ({ session: harness.session, api: harness.api }) }));
function session(id = "first"): Session {
  return { access_token: `synthetic-${id}`, refresh_token: "synthetic-refresh", token_type: "Bearer", expires_in: 900,
    tenant: { id: `tenant-${id}`, name: "Synthetic workspace", slug: id, status: "active" },
    user: { id: `user-${id}`, tenant_id: `tenant-${id}`, display_name: "Owner", account_type: "human", access_scope: "workspace", role: "owner", status: "active" },
    device: { id: `device-${id}`, user_id: `user-${id}`, name: "Browser", platform: "web" } };
}
function View() { return <StepUpProvider><UsageReportsPanel api={harness.api} /></StepUpProvider>; }
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>((done) => { resolve = done; }); return { promise, resolve }; }
async function loaded() { await screen.findByRole("region", { name: "Accounts usage" }); }

describe("retained usage reports", () => {
  beforeEach(() => {
    harness.session = session();
    harness.api.usageReport.mockReset().mockResolvedValue(usageFixture());
    harness.api.exportUsageReport.mockReset();
    harness.api.stepUp.mockReset().mockResolvedValue({ step_up_at: "2000-01-03T12:00:00Z" });
  });

  it("distinguishes an available zero from unavailable null sources and separately shows daily duration", async () => {
    render(<View />); await loaded();
    expect(harness.api.usageReport).toHaveBeenCalledWith({});
    const conversations = screen.getByRole("region", { name: "Conversations usage" });
    expect(within(conversations).getByText("Active retained conversations").nextElementSibling).toHaveTextContent("0");
    const attachments = screen.getByRole("region", { name: "Attachments usage" });
    expect(attachments).toHaveTextContent("Source unavailable");
    expect(within(attachments).queryByText("0")).not.toBeInTheDocument();
    const calls = screen.getByRole("region", { name: "Meeting calls usage" });
    await userEvent.setup().click(within(calls).getByText("Daily retained records for meeting calls"));
    const metric = within(calls).getByLabelText("Daily meeting calls metric");
    await userEvent.setup().selectOptions(metric, "observed_room_seconds");
    const rows = within(calls).getAllByRole("row");
    expect(rows[1]).toHaveTextContent("2000-01-01"); expect(rows[1]).toHaveTextContent("120");
    await userEvent.setup().selectOptions(metric, "started");
    expect(within(calls).getAllByRole("row")[1]).toHaveTextContent("0");
    expect(screen.getByText(/Active humans include conversation-only accounts/)).toBeVisible();
  });

  it("rejects an inclusive32-day or future window without sending a new request", async () => {
    render(<View />); await loaded();
    fireEvent.change(screen.getByLabelText("From (UTC)"), { target: { value: "2000-01-01" } });
    fireEvent.change(screen.getByLabelText("Through (UTC, inclusive)"), { target: { value: "2000-02-01" } });
    await userEvent.setup().click(screen.getByRole("button", { name: "Apply date window" }));
    await screen.findByText(/Choose a valid inclusive UTC date range/);
    expect(harness.api.usageReport).toHaveBeenCalledTimes(1);
    fireEvent.change(screen.getByLabelText("Through (UTC, inclusive)"), { target: { value: "2099-01-01" } });
    await userEvent.setup().click(screen.getByRole("button", { name: "Apply date window" }));
    expect(harness.api.usageReport).toHaveBeenCalledTimes(1);
  });

  it("exports the applied server window rather than unapplied edited dates and shows actual metadata", async () => {
    const originalCreate = Object.getOwnPropertyDescriptor(URL, "createObjectURL");
    const originalRevoke = Object.getOwnPropertyDescriptor(URL, "revokeObjectURL");
    Object.defineProperty(URL, "createObjectURL", { configurable: true, value: vi.fn().mockReturnValue("blob:synthetic-usage") });
    const revoke = vi.fn(); Object.defineProperty(URL, "revokeObjectURL", { configurable: true, value: revoke });
    const click = vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => undefined);
    harness.api.exportUsageReport.mockResolvedValue({ blob: new Blob(["synthetic aggregate CSV"]), filename: "usage-2000-01-01-2000-01-02.csv",
      usage: { from: "2000-01-01", through: "2000-01-02", timeZone: "UTC", observedAt: "2000-01-03T13:00:00Z", unavailableSources: 2 } });
    try {
      render(<View />); await loaded();
      fireEvent.change(screen.getByLabelText("From (UTC)"), { target: { value: "2000-01-02" } });
      await userEvent.setup().click(screen.getByRole("button", { name: "Export applied usage CSV" }));
      const receipt = await screen.findByText(/Downloaded retained usage for 2000-01-01 through 2000-01-02 UTC/);
      expect(receipt).toHaveTextContent("2 sources unavailable");
      expect(receipt).toHaveTextContent("not an immutable or billing snapshot");
      expect(harness.api.exportUsageReport).toHaveBeenCalledWith({ from: "2000-01-01", through: "2000-01-02" });
      expect(click).toHaveBeenCalledTimes(1); expect(revoke).toHaveBeenCalledWith("blob:synthetic-usage");
    } finally {
      click.mockRestore();
      if (originalCreate) Object.defineProperty(URL, "createObjectURL", originalCreate); else Reflect.deleteProperty(URL, "createObjectURL");
      if (originalRevoke) Object.defineProperty(URL, "revokeObjectURL", originalRevoke); else Reflect.deleteProperty(URL, "revokeObjectURL");
    }
  });

  it("clears every cached source after export denial while keeping harmless date input", async () => {
    harness.api.exportUsageReport.mockRejectedValue(new ApiError(403, "forbidden", "Private provider detail"));
    render(<View />); await loaded();
    await userEvent.setup().click(screen.getByRole("button", { name: "Export applied usage CSV" }));
    await screen.findByText(/Usage details are unavailable with your current access/);
    expect(screen.queryByRole("region", { name: "Accounts usage" })).not.toBeInTheDocument();
    expect(screen.queryByText("Private provider detail")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Export applied usage CSV" })).toBeDisabled();
    expect(screen.getByLabelText("From (UTC)")).toHaveValue("2000-01-01");
  });

  it("revalidates the same applied window on focus and clears revoked private metrics", async () => {
    render(<View />); await loaded();
    harness.api.usageReport.mockRejectedValue(new ApiError(403, "forbidden", "Access revoked"));
    fireEvent.focus(window);
    await screen.findByText(/Usage details are unavailable with your current access/);
    expect(harness.api.usageReport).toHaveBeenLastCalledWith({ from: "2000-01-01", through: "2000-01-02" });
    expect(screen.queryByText("Retained message records")).not.toBeInTheDocument();
  });

  it("ignores a delayed previous identity report after the next identity has loaded", async () => {
    const old = deferred<UsageReport>();
    const next = usageFixture();
    if (next.sources.identity.status === "available") next.sources.identity.data.current.active_humans = 42;
    harness.api.usageReport.mockReturnValueOnce(old.promise).mockResolvedValue(next);
    const view = render(<View />);
    await waitFor(() => expect(harness.api.usageReport).toHaveBeenCalledTimes(1));
    harness.session = session("second"); view.rerender(<View />); await loaded();
    await act(async () => old.resolve(usageFixture()));
    expect(screen.getByText("Active human accounts").nextElementSibling).toHaveTextContent("42");
  });

  it.each(["compliance_admin", "member"] as const)("does not request aggregate usage for %s", async (role) => {
    harness.session!.user.role = role; render(<View />);
    expect(screen.getByRole("alert")).toHaveTextContent("current owner or administrator");
    expect(harness.api.usageReport).not.toHaveBeenCalled();
  });

  it("does not enroll a conversation-only owner into aggregate reporting", () => {
    harness.session!.user.access_scope = "conversation_only"; render(<View />);
    expect(screen.getByRole("alert")).toHaveTextContent("full workspace access");
    expect(harness.api.usageReport).not.toHaveBeenCalled();
  });

  it("clears cached sources if actual verification succeeds but its retried read is denied", async () => {
    render(<View />); await loaded();
    harness.api.usageReport.mockRejectedValueOnce(new ApiError(428, "step_up_required", "Verification required"))
      .mockRejectedValueOnce(new ApiError(403, "forbidden", "Access revoked"));
    const user = userEvent.setup(); await user.click(screen.getByRole("button", { name: "Refresh applied window" }));
    const dialog = await screen.findByRole("dialog", { name: "Confirm it is you" });
    await user.type(within(dialog).getByLabelText("Current password"), "synthetic-current-password");
    await user.click(within(dialog).getByRole("button", { name: "Continue" }));
    await screen.findByText(/Usage details are unavailable with your current access/);
    expect(harness.api.usageReport.mock.calls.slice(1)).toEqual([
      [{ from: "2000-01-01", through: "2000-01-02" }], [{ from: "2000-01-01", through: "2000-01-02" }]
    ]);
    expect(screen.queryByRole("region", { name: "Accounts usage" })).not.toBeInTheDocument();
    await user.click(within(dialog).getByRole("button", { name: "Cancel" }));
  });
});
