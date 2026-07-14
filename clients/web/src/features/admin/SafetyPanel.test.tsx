import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import type { ModerationCase } from "../../types";
import { SafetyPanel } from "./SafetyPanel";

vi.mock("../../app/step-up", () => ({
  useStepUp: () => ({ runWithStepUp: <T,>(action: () => Promise<T>) => action() }),
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
