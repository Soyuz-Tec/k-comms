import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import type { Conversation, GuestLink } from "../../types";
import { CallReadinessLauncher } from "./CallReadinessLauncher";

vi.mock("../guest/QrCode", () => ({
  QrCode: ({ value }: { value: string }) => <output data-testid="qr-value">{value}</output>
}));

const conversation: Conversation = {
  id: "conversation-uae-test",
  tenant_id: "tenant-1",
  kind: "group",
  title: "UAE office call test",
  counterpart_user_id: null,
  counterpart_display_name: null,
  visibility: "private",
  latest_sequence: 0,
  inserted_at: "2026-08-06T12:00:00Z",
  updated_at: "2026-08-06T12:00:00Z"
};

const guestLink: GuestLink = {
  id: "guest-link-1",
  conversation_id: conversation.id,
  expires_at: "2026-08-06T12:10:00Z",
  max_uses: 1,
  use_count: 0,
  status: "active"
};

describe("CallReadinessLauncher", () => {
  it("creates a private room and a one-use ten-minute readiness link", async () => {
    const createConversation = vi.fn().mockResolvedValue(conversation);
    const createGuestLink = vi.fn().mockResolvedValue({
      guestLink,
      token: "not-rendered",
      url: "https://comms.example.test/join#guest=fragment-secret"
    });
    const user = userEvent.setup();

    render(
      <MemoryRouter>
        <CallReadinessLauncher
          api={{ createGuestLink } as unknown as ApiClient}
          audioAvailable
          createConversation={createConversation}
        />
      </MemoryRouter>
    );

    await user.click(screen.getByText("Office connection test"));
    await user.click(screen.getByRole("button", { name: "Create test link" }));

    await waitFor(() => expect(createConversation).toHaveBeenCalledWith({
      title: "UAE office call test",
      kind: "group",
      visibility: "private",
      member_ids: []
    }));
    expect(createGuestLink).toHaveBeenCalledWith(conversation.id, {
      expires_in_seconds: 600,
      max_uses: 1
    });
    const url = new URL((screen.getByLabelText("One-use office link") as HTMLInputElement).value);
    expect(url.searchParams.get("call")).toBe("audio");
    expect(url.searchParams.get("call_readiness")).toBe("office");
    expect(url.hash).toBe("#guest=fragment-secret");
    expect(screen.queryByText("not-rendered")).not.toBeInTheDocument();
  });

  it("does not allow a test to start while audio calling is unavailable", async () => {
    const user = userEvent.setup();
    render(
      <MemoryRouter>
        <CallReadinessLauncher
          api={{} as ApiClient}
          audioAvailable={false}
          createConversation={vi.fn()}
        />
      </MemoryRouter>
    );

    await user.click(screen.getByText("Office connection test"));
    expect(screen.getByRole("button", { name: "Create test link" })).toBeDisabled();
    expect(screen.getByText("Audio calling is unavailable.")).toBeVisible();
  });
});
