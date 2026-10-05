import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import { ApiError } from "../../api/errors";
import type { Session } from "../../types";
import type { DeletionHistoryPage } from "../../types/deletionHistory";
import { StepUpProvider } from "../../app/step-up";
import { DeletionTimeline } from "./DeletionTimeline";
import { historyEvent, historyPage } from "./deletionTimeline.testSupport";

const harness = vi.hoisted(() => ({ session: null as Session | null, api: {
  deletionHistory: vi.fn(), exportDeletionHistory: vi.fn(), stepUp: vi.fn()
} }));
vi.mock("../../app/session", () => ({ useSession: () => ({ session: harness.session, api: harness.api }) }));
function syntheticSession(id = "first"): Session {
  return { access_token: `synthetic-${id}`, refresh_token: "synthetic-refresh", token_type: "Bearer", expires_in: 900,
    tenant: { id: `tenant-${id}`, name: "Synthetic workspace", slug: id, status: "active" },
    user: { id: `user-${id}`, tenant_id: `tenant-${id}`, display_name: "Reviewer", role: "owner", status: "active" },
    device: { id: `device-${id}`, user_id: `user-${id}`, name: "Browser", platform: "web" } };
}
function View() { return <StepUpProvider><DeletionTimeline api={harness.api as unknown as ApiClient} requestId="deletion-1" /></StepUpProvider>; }
async function openHistory() {
  await userEvent.setup().click(screen.getByText("Request details and history"));
  await screen.findByText("History Reviewer", { exact: false });
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((complete) => { resolve = complete; });
  return { promise, resolve };
}

describe("retained deletion-history review", () => {
  beforeEach(() => {
    harness.session = syntheticSession();
    harness.api.deletionHistory.mockReset().mockResolvedValue(historyPage());
    harness.api.exportDeletionHistory.mockReset();
    harness.api.stepUp.mockReset().mockResolvedValue({ step_up_at: "2026-10-05T00:03:00Z" });
  });

  it("loads history only on review and renders only explicit safe facts with truthful coverage", async () => {
    harness.api.deletionHistory.mockResolvedValue(historyPage({ request: {
      ...historyPage().request, evidence: { messages_tombstoned: 3, writer_fence_erasure_version: 1,
        provider_key: "synthetic-private-provider-key", actor_secret: "synthetic-private-actor-secret", deleted_object_count: -1 }
    } }));
    render(<View />);
    expect(harness.api.deletionHistory).not.toHaveBeenCalled();
    await openHistory();
    expect(harness.api.deletionHistory).toHaveBeenCalledWith("deletion-1", { limit: 25 });
    expect(screen.getByText("Version lineage is unproven. Retained events do not establish every historical request version.")).toBeVisible();
    expect(screen.getByText("Messages tombstoned").nextElementSibling).toHaveTextContent("3");
    expect(screen.getByText("Write admission fence").nextElementSibling).toHaveTextContent("1");
    expect(screen.queryByText(/synthetic-private/)).not.toBeInTheDocument();
    expect(screen.queryByText("Objects deleted")).not.toBeInTheDocument();
    expect(screen.queryByText("synthetic-snapshot")).not.toBeInTheDocument();
  });

  it("paginates the frozen membership using the opaque cursor and preserves chronological events", async () => {
    const approved = historyEvent({ id: "synthetic-approved-event", action: "deletion_request.approved", status: "approved", inserted_at: "2026-10-05T00:01:00Z", version: 2 });
    harness.api.deletionHistory.mockResolvedValueOnce(historyPage({ next_cursor: "synthetic-next-cursor" }))
      .mockResolvedValueOnce(historyPage({ events: [approved] }));
    render(<View />);
    await openHistory();
    await userEvent.setup().click(screen.getByRole("button", { name: "Load more history events" }));
    await screen.findByText("Approved");
    expect(harness.api.deletionHistory).toHaveBeenLastCalledWith("deletion-1", { cursor: "synthetic-next-cursor" });
    const entries = within(screen.getByRole("list", { name: "Chronological deletion events" })).getAllByRole("listitem");
    expect(entries).toHaveLength(2);
    expect(entries[0]).toHaveTextContent("Requested");
    expect(entries[1]).toHaveTextContent("Approved");
  });

  it("requires a deliberate new capture after expiration instead of silently replacing reviewed evidence", async () => {
    harness.api.deletionHistory.mockResolvedValueOnce(historyPage({ next_cursor: "synthetic-expired-cursor" }))
      .mockRejectedValueOnce(new ApiError(422, "invalid_history_cursor", "Expired"))
      .mockResolvedValueOnce(historyPage({ snapshot: "synthetic-new-snapshot", events: [historyEvent({ action: "deletion_request.completed", status: "completed" })] }));
    render(<View />);
    await openHistory();
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: "Load more history events" }));
    await screen.findByText(/This history snapshot has expired/);
    expect(harness.api.deletionHistory).toHaveBeenCalledTimes(2);
    expect(screen.getByRole("button", { name: "Export this history CSV" })).toBeDisabled();
    await user.click(screen.getByRole("button", { name: "Capture current history" }));
    await screen.findByText("Completed");
    expect(harness.api.deletionHistory).toHaveBeenLastCalledWith("deletion-1", { limit: 25 });
    expect(screen.queryByText("Requested")).not.toBeInTheDocument();
  });

  it("clears loaded actor names, events, request facts and snapshot after an export access denial", async () => {
    harness.api.exportDeletionHistory.mockRejectedValue(new ApiError(403, "forbidden", "Synthetic private provider reason"));
    render(<View />);
    await openHistory();
    await userEvent.setup().click(screen.getByRole("button", { name: "Export this history CSV" }));
    await screen.findByText(/Deletion history is unavailable with your current access/);
    expect(harness.api.exportDeletionHistory).toHaveBeenCalledWith("deletion-1", "synthetic-snapshot", 5000);
    expect(screen.queryByText(/History Reviewer|^Requested$|Synthetic private provider reason/)).not.toBeInTheDocument();
    expect(screen.queryByText("Messages tombstoned")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Export this history CSV" })).toBeDisabled();
  });

  it("clears cached detail on focus revalidation denial without recapturing current history", async () => {
    render(<View />);
    await openHistory();
    harness.api.deletionHistory.mockRejectedValue(new ApiError(403, "forbidden", "Access revoked"));
    fireEvent.focus(window);
    await screen.findByText(/Deletion history is unavailable with your current access/);
    expect(harness.api.deletionHistory).toHaveBeenLastCalledWith("deletion-1", { snapshot: "synthetic-snapshot", limit: 25 });
    expect(screen.queryByText(/History Reviewer/)).not.toBeInTheDocument();
  });

  it("downloads only the verified reviewed snapshot and discloses its retained/truncated receipt", async () => {
    const originalCreate = Object.getOwnPropertyDescriptor(URL, "createObjectURL");
    const originalRevoke = Object.getOwnPropertyDescriptor(URL, "revokeObjectURL");
    const create = vi.fn().mockReturnValue("blob:synthetic-history");
    const revoke = vi.fn();
    Object.defineProperty(URL, "createObjectURL", { configurable: true, value: create });
    Object.defineProperty(URL, "revokeObjectURL", { configurable: true, value: revoke });
    const click = vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => undefined);
    harness.api.exportDeletionHistory.mockResolvedValue({ blob: new Blob(["synthetic safe CSV"]), filename: "deletion-request-history.csv", count: 5000, truncated: true,
      history: { snapshot: "synthetic-snapshot", coverage: "partial", maximumRows: 5000, retainedOnly: true, observedAt: "2026-10-05T00:03:00Z" } });
    try {
      render(<View />);
      await openHistory();
      await userEvent.setup().click(screen.getByRole("button", { name: "Export this history CSV" }));
      const receipt = await screen.findByText(/Downloaded 5000 retained history events from this snapshot/);
      expect(receipt).toHaveTextContent("Coverage: partial");
      expect(receipt).toHaveTextContent("truncated");
      expect(receipt).toHaveTextContent("not proof of a complete lifetime record");
      expect(click).toHaveBeenCalledTimes(1);
      expect(create).toHaveBeenCalledTimes(1);
      expect(revoke).toHaveBeenCalledWith("blob:synthetic-history");
    } finally {
      click.mockRestore();
      if (originalCreate) Object.defineProperty(URL, "createObjectURL", originalCreate); else Reflect.deleteProperty(URL, "createObjectURL");
      if (originalRevoke) Object.defineProperty(URL, "revokeObjectURL", originalRevoke); else Reflect.deleteProperty(URL, "revokeObjectURL");
    }
  });

  it("does not disclose a delayed old-session response after another identity starts a review", async () => {
    const old = deferred<DeletionHistoryPage>();
    harness.api.deletionHistory.mockReturnValueOnce(old.promise).mockResolvedValue(historyPage({ events: [historyEvent({ actor: { kind: "user", user_id: "new-reviewer", display_name: "Next identity reviewer" } })] }));
    const view = render(<View />);
    const user = userEvent.setup();
    await user.click(screen.getByText("Request details and history"));
    await waitFor(() => expect(harness.api.deletionHistory).toHaveBeenCalledTimes(1));
    harness.session = syntheticSession("second");
    view.rerender(<View />);
    await user.click(screen.getByText("Request details and history"));
    await screen.findByText(/Next identity reviewer/);
    await act(async () => old.resolve(historyPage()));
    expect(screen.queryByText(/History Reviewer/)).not.toBeInTheDocument();
    expect(screen.getByText(/Next identity reviewer/)).toBeVisible();
  });

  it("retries the same frozen cursor after actual step-up and clears detail if that retry is denied", async () => {
    harness.api.deletionHistory.mockResolvedValueOnce(historyPage({ next_cursor: "synthetic-stepup-cursor" }))
      .mockRejectedValueOnce(new ApiError(428, "step_up_required", "Recent verification required"))
      .mockRejectedValueOnce(new ApiError(403, "forbidden", "Access revoked after verification"));
    render(<View />);
    await openHistory();
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: "Load more history events" }));
    const dialog = await screen.findByRole("dialog", { name: "Confirm it is you" });
    await user.type(within(dialog).getByLabelText("Current password"), "synthetic-current-password");
    await user.click(within(dialog).getByRole("button", { name: "Continue" }));
    await screen.findByText(/Deletion history is unavailable with your current access/);
    expect(harness.api.stepUp).toHaveBeenCalledWith("synthetic-current-password", undefined);
    expect(harness.api.deletionHistory.mock.calls.slice(1)).toEqual([
      ["deletion-1", { cursor: "synthetic-stepup-cursor" }], ["deletion-1", { cursor: "synthetic-stepup-cursor" }]
    ]);
    expect(screen.queryByText(/History Reviewer/)).not.toBeInTheDocument();
    await user.click(within(dialog).getByRole("button", { name: "Cancel" }));
  });
});
