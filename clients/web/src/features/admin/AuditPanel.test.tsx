import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import { StepUpProvider } from "../../app/step-up";
import type { AuditEvent } from "../../types";
import type { User } from "../../types";
import {
  duplicateParticipantNames,
  participantIdentifier
} from "../../lib/participantIdentity";
import { AuditPanel } from "./AuditPanel";

vi.mock("../../app/session", () => ({ useSession: () => ({ api: { stepUp: vi.fn() } }) }));

afterEach(() => vi.restoreAllMocks());

describe("AuditPanel export", () => {
  it("exports the active filter and announces a capped CSV download", async () => {
    const event: AuditEvent = {
      id: "audit-1",
      actor_user_id: "user-1",
      action: "user.created",
      resource_type: "user",
      resource_id: "user-2",
      metadata: {},
      request_id: "request-1",
      inserted_at: "2026-07-12T10:00:00Z"
    };
    const exportAuditEvents = vi.fn().mockResolvedValue({
      blob: new Blob(["\"action\"\r\n\"user.created\"\r\n"], { type: "text/csv" }),
      filename: "k-comms-audit-20260712T100000Z.csv",
      count: 5_000,
      truncated: true
    });
    const api = {
      auditEventsPage: vi.fn().mockResolvedValue({ data: [event], page: { limit: 100, next_cursor: null } }),
      exportAuditEvents
    } as unknown as ApiClient;
    const createObjectURL = vi.fn().mockReturnValue("blob:audit-export");
    const revokeObjectURL = vi.fn();
    Object.defineProperty(URL, "createObjectURL", { value: createObjectURL, configurable: true });
    Object.defineProperty(URL, "revokeObjectURL", { value: revokeObjectURL, configurable: true });
    const click = vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => undefined);
    const user = userEvent.setup();
    render(<StepUpProvider><AuditPanel api={api} users={[]} /></StepUpProvider>);

    await user.type(screen.getByLabelText("Search audit events"), "user.created");
    await user.click(screen.getByRole("button", { name: "Apply filters" }));
    await waitFor(() => expect(screen.getByRole("button", { name: "Export audit CSV" })).toBeEnabled());
    await user.click(screen.getByRole("button", { name: "Export audit CSV" }));

    expect(exportAuditEvents).toHaveBeenCalledWith({ q: "user.created", limit: 5_000 });
    expect(createObjectURL).toHaveBeenCalledWith(expect.any(Blob));
    expect(click).toHaveBeenCalledOnce();
    expect(revokeObjectURL).toHaveBeenCalledWith("blob:audit-export");
    expect(await screen.findByRole("status")).toHaveTextContent("Downloaded 5000 audit events");
    expect(screen.getByRole("status")).toHaveTextContent("5,000-row limit");
  });

  it("disambiguates duplicate actor usernames in the audit list", async () => {
    const users = [
      {
        id: "actor-one",
        tenant_id: "tenant-1",
        display_name: "Alex",
        email: "alex.one@example.test",
        account_type: "human",
        role: "member",
        status: "active"
      },
      {
        id: "actor-two",
        tenant_id: "tenant-1",
        display_name: "ALEX",
        email: "alex.two@example.test",
        account_type: "human",
        role: "member",
        status: "active"
      }
    ] satisfies User[];
    const events = users.map((actor, index) => ({
      id: `audit-${index}`,
      actor_user_id: actor.id,
      action: "message.sent",
      resource_type: "message",
      resource_id: `message-${index}`,
      metadata: {},
      request_id: `request-${index}`,
      inserted_at: "2026-07-12T10:00:00Z"
    } satisfies AuditEvent));
    const api = {
      auditEventsPage: vi.fn().mockResolvedValue({ data: events, page: { limit: 100, next_cursor: null } })
    } as unknown as ApiClient;
    const duplicates = duplicateParticipantNames(users);

    render(
      <StepUpProvider>
        <AuditPanel api={api} users={users} />
      </StepUpProvider>
    );

    for (const actor of users) {
      expect(
        await screen.findByRole("cell", { name: participantIdentifier(actor, duplicates) })
      ).toBeVisible();
    }
  });
});


describe("AuditPanel server evidence", () => {
  it("pages matching results, retains rows on failure and exposes complete metadata", async () => {
    const event: AuditEvent = { id: "audit-full-id", actor_user_id: "actor-full-id", action: "message.updated", resource_type: "message", resource_id: "message-complete-identifier", request_id: "request-complete-identifier", metadata: { reason: "Correction reviewed" }, inserted_at: "2026-07-12T10:00:00Z" };
    const auditEventsPage = vi.fn().mockResolvedValueOnce({ data: [event], page: { limit: 100, next_cursor: "next-page" } }).mockRejectedValueOnce(new Error("Connection interrupted")).mockResolvedValueOnce({ data: [event, { ...event, id: "second-audit", action: "message.deleted" }], page: { limit: 100, next_cursor: null } });
    const api = { auditEventsPage } as unknown as ApiClient;
    const user = userEvent.setup();
    render(<StepUpProvider><AuditPanel api={api} users={[]} /></StepUpProvider>);
    await user.click(await screen.findByRole("button", { name: "Load more audit events" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Connection interrupted");
    expect(screen.getByText("message.updated")).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Load more audit events" }));
    expect(await screen.findByText("message.deleted")).toBeVisible();
    expect(screen.getAllByText("message.updated")).toHaveLength(1);
    expect(auditEventsPage).toHaveBeenLastCalledWith({ limit: 100 }, "next-page");
    expect(screen.queryByRole("button", { name: "Load more audit events" })).not.toBeInTheDocument();
    await user.click(screen.getAllByText("Event details")[0]!);
    expect(screen.getAllByText("message-complete-identifier")[0]).toBeVisible();
    expect(screen.getAllByText(/Correction reviewed/)[0]).toBeVisible();
  });

  it("exports applied structured filters rather than unsubmitted edits", async () => {
    const auditEventsPage = vi.fn().mockResolvedValue({ data: [], page: { limit: 100, next_cursor: null } });
    const exportAuditEvents = vi.fn().mockResolvedValue({ blob: new Blob(), filename: "audit.csv", count: 0, truncated: false });
    Object.defineProperty(URL, "createObjectURL", { value: vi.fn().mockReturnValue("blob:export"), configurable: true });
    Object.defineProperty(URL, "revokeObjectURL", { value: vi.fn(), configurable: true });
    vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => undefined);
    const user = userEvent.setup();
    render(<StepUpProvider><AuditPanel api={{ auditEventsPage, exportAuditEvents } as unknown as ApiClient} users={[]} /></StepUpProvider>);
    await user.type(screen.getByLabelText("Action"), "user.updated");
    await user.type(screen.getByLabelText("Resource type"), "user");
    await user.click(screen.getByRole("button", { name: "Apply filters" }));
    await waitFor(() => expect(auditEventsPage).toHaveBeenLastCalledWith({ action: "user.updated", resource_type: "user", limit: 100 }, undefined));
    await user.type(screen.getByLabelText("Search audit events"), "unapplied");
    await user.click(screen.getByRole("button", { name: "Export audit CSV" }));
    expect(exportAuditEvents).toHaveBeenCalledWith({ action: "user.updated", resource_type: "user", limit: 5000 });
  });
});


describe("AuditPanel export concurrency", () => {
  it("keeps the applied scope fixed while an export is pending and permits the preserved draft afterward", async () => {
    let finishExport!: (file: { blob: Blob; filename: string; count: number; truncated: boolean }) => void;
    const pendingExport = new Promise<{ blob: Blob; filename: string; count: number; truncated: boolean }>((resolve) => { finishExport = resolve; });
    const auditEventsPage = vi.fn().mockResolvedValue({ data: [], page: { limit: 100, next_cursor: null } });
    const exportAuditEvents = vi.fn().mockReturnValue(pendingExport);
    Object.defineProperty(URL, "createObjectURL", { value: vi.fn().mockReturnValue("blob:pending-export"), configurable: true });
    Object.defineProperty(URL, "revokeObjectURL", { value: vi.fn(), configurable: true });
    vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => undefined);
    const user = userEvent.setup();
    render(<StepUpProvider><AuditPanel api={{ auditEventsPage, exportAuditEvents } as unknown as ApiClient} users={[]} /></StepUpProvider>);
    await user.type(screen.getByLabelText("Search audit events"), "original scope");
    await user.click(screen.getByRole("button", { name: "Apply filters" }));
    await waitFor(() => expect(screen.getByRole("button", { name: "Export audit CSV" })).toBeEnabled());
    await user.click(screen.getByRole("button", { name: "Export audit CSV" }));
    expect(exportAuditEvents).toHaveBeenCalledExactlyOnceWith({ q: "original scope", limit: 5000 });
    expect(screen.getByRole("button", { name: "Exporting…" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Apply filters" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Reset filters" })).toBeDisabled();
    await user.clear(screen.getByLabelText("Search audit events"));
    await user.type(screen.getByLabelText("Search audit events"), "later scope");
    const count = auditEventsPage.mock.calls.length;
    fireEvent.submit(screen.getByLabelText("Search audit events").closest("form")!);
    expect(auditEventsPage).toHaveBeenCalledTimes(count);
    await act(async () => { finishExport({ blob: new Blob(), filename: "original.csv", count: 1, truncated: false }); });
    expect(await screen.findByRole("status")).toHaveTextContent("Downloaded 1 audit events");
    await user.click(screen.getByRole("button", { name: "Apply filters" }));
    await waitFor(() => expect(auditEventsPage).toHaveBeenLastCalledWith({ q: "later scope", limit: 100 }, undefined));
    expect(screen.queryByRole("status")).not.toBeInTheDocument();
  });
});
