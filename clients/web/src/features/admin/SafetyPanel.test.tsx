import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import type { ModerationCase } from "../../types";
import { SafetyPanel } from "./SafetyPanel";

const { runWithStepUp } = vi.hoisted(() => ({ runWithStepUp: <T,>(action: () => Promise<T>) => action() }));

vi.mock("../../app/step-up", () => ({
  useStepUp: () => ({ runWithStepUp }),
  stepUpWasCancelled: () => false
}));

const moderationCase: ModerationCase = {
  id: "case-1",
  reporter_user_id: "user-1",
  category: "message_content",
  summary: "Review this message",
  details: "Reported details",
  priority: "normal",
  status: "open",
  version: 1,
  inserted_at: "2026-07-12T10:00:00Z",
  updated_at: "2026-07-12T10:00:00Z"
};

describe("SafetyPanel role scoping", () => {
  it("gives moderation-load errors a descriptive dismiss control", async () => {
    const user = userEvent.setup();
    const api = {
      moderationCases: vi.fn().mockRejectedValue(new Error("Moderation unavailable"))
    } as unknown as ApiClient;

    render(<SafetyPanel api={api} canManageAttachments={false} />);

    const dismiss = await screen.findByRole("button", { name: "Dismiss safety error" });
    expect(screen.getByRole("alert")).toHaveTextContent("Moderation unavailable");
    await user.click(dismiss);
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("loads moderation for a moderator without requesting owner-only attachment administration", async () => {
    const attachmentSafety = vi.fn();
    const api = {
      moderationCases: vi.fn().mockResolvedValue([moderationCase]),
      attachmentSafety
    } as unknown as ApiClient;

    render(<SafetyPanel api={api} canManageAttachments={false} />);

    expect(await screen.findByText("Review this message")).toBeInTheDocument();
    expect(attachmentSafety).not.toHaveBeenCalled();
    expect(screen.queryByRole("heading", { name: "Attachment safety" })).not.toBeInTheDocument();
  });

  it("reviews a moderation decision and retains its audited note", async () => {
    const addModerationAction = vi.fn().mockResolvedValue({ ...moderationCase, status: "resolved", version: 2 });
    const api = {
      moderationCases: vi.fn().mockResolvedValue([moderationCase]),
      addModerationAction
    } as unknown as ApiClient;
    const user = userEvent.setup();
    render(<SafetyPanel api={api} canManageAttachments={false} />);

    await user.click(await screen.findByRole("button", { name: "Resolve" }));
    expect(screen.getByRole("alertdialog", { name: "Resolve case?" })).toHaveTextContent("Review this message");
    await user.type(screen.getByRole("textbox", { name: "Decision note" }), "Confirmed policy violation");
    await user.click(screen.getByRole("button", { name: "Resolve" }));

    await waitFor(() => expect(addModerationAction).toHaveBeenCalledWith("case-1", {
      action_type: "resolve",
      note: "Confirmed policy violation",
      version: 1
    }));
  });
});


describe("SafetyPanel case evidence", () => {
  it("filters cases and loads full decisions through a retryable accessible detail dialog", async () => {
    const detailCase = { ...moderationCase, conversation_id: "conversation-1", message_id: "message-1" };
    const moderationCaseDetail = vi.fn().mockRejectedValueOnce(new Error("Case evidence unavailable")).mockResolvedValueOnce({ data: detailCase, actions: [{ id: "action-1", actor_user_id: "reviewer-1", action_type: "start_review", note: "Source checked carefully", inserted_at: "2026-07-12T10:01:00Z" }] });
    const api = { moderationCases: vi.fn().mockResolvedValue([detailCase, { ...moderationCase, id: "case-closed", summary: "Closed urgent report", priority: "urgent", status: "resolved" }]), moderationCase: moderationCaseDetail } as unknown as ApiClient;
    const user = userEvent.setup();
    render(<SafetyPanel api={api} canManageAttachments={false} />);
    await screen.findByText("Closed urgent report");
    await user.selectOptions(screen.getByLabelText("Case status"), "open");
    expect(screen.queryByText("Closed urgent report")).not.toBeInTheDocument();
    await waitFor(() => expect(api.moderationCases).toHaveBeenLastCalledWith({ status: "open", limit: 100 }));
    await screen.findByText("Review this message");
    await user.type(screen.getByLabelText("Search loaded cases"), "Reported details");
    const opener = screen.getByRole("button", { name: "Case details" });
    await user.click(opener);
    let dialog = screen.getByRole("dialog", { name: "Moderation case details" });
    expect(await within(dialog).findByRole("alert")).toHaveTextContent("Case evidence unavailable");
    await user.click(within(dialog).getByRole("button", { name: "Retry case details" }));
    dialog = screen.getByRole("dialog", { name: "Moderation case details" });
    expect(await within(dialog).findByText("Source checked carefully")).toBeVisible();
    expect(within(dialog).getByText("Actor reviewer-1", { exact: false })).toBeVisible();
    expect(within(dialog).getByRole("link", { name: "Open source conversation" })).toHaveAttribute("href", "/app/?conversation=conversation-1&message=message-1");
    expect(moderationCaseDetail).toHaveBeenCalledTimes(2);
    await user.keyboard("{Escape}");
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
    await waitFor(() => expect(opener).toHaveFocus());
  });

  it("filters scan states and exposes recorded attempts without presenting them as successful", async () => {
    const api = { moderationCases: vi.fn().mockResolvedValue([]), attachmentSafety: vi.fn().mockResolvedValue([{ id: "file-1", file_name: "unavailable.pdf", byte_size: 10, status: "scan_failed", scan_status: "failed", scan_provider: "configured-provider", scan_attempts: 1, scan_error_code: "provider_unreachable", attempts: [{ id: "attempt-1", attempt_number: 1, provider: "configured-provider", status: "failed", started_at: "2026-07-12T10:00:00Z", error_code: "provider_unreachable" }] }, { id: "file-2", file_name: "available.pdf", byte_size: 10, status: "ready", scan_status: "clean", attempts: [] }]) } as unknown as ApiClient;
    const user = userEvent.setup();
    render(<SafetyPanel api={api} canManageAttachments />);
    await screen.findByText("unavailable.pdf");
    await user.selectOptions(screen.getByLabelText("Scan status"), "failed");
    expect(screen.queryByText("available.pdf")).not.toBeInTheDocument();
    await waitFor(() => expect(api.attachmentSafety).toHaveBeenLastCalledWith({ scan_status: "failed", limit: 100 }));
    await screen.findByText("unavailable.pdf");
    await user.click(screen.getByText("Scan details"));
    expect(screen.getByText(/Attempt 1 · failed/)).toBeVisible();
    expect(screen.getByRole("button", { name: "Retry scan" })).toBeEnabled();
    expect(screen.queryByText("Live API")).not.toBeInTheDocument();
  });
});
