import { render, screen } from "@testing-library/react";
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
});
