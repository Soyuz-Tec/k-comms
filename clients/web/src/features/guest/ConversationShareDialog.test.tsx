import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import type { Conversation } from "../../types";
import { ConversationShareDialog } from "./ConversationShareDialog";

vi.mock("./QrCode", () => ({
  QrCode: ({ value }: { value: string }) => <output aria-label="QR value">{value}</output>
}));

const room: Conversation = {
  id: "conversation-1",
  tenant_id: "tenant-1",
  kind: "group",
  title: "Launch room",
  counterpart_display_name: null,
  visibility: "private",
  latest_sequence: 0,
  membership_role: "owner",
  inserted_at: "2026-07-24T12:00:00Z",
  updated_at: "2026-07-24T12:00:00Z"
};

describe("ConversationShareDialog", () => {
  const createGuestLink = vi.fn();
  const revokeGuestLink = vi.fn();
  const guestLinks = vi.fn();

  beforeEach(() => {
    createGuestLink.mockReset().mockResolvedValue({
      guestLink: {
        id: "link-1",
        conversation_id: room.id,
        expires_at: "2026-07-25T12:00:00Z",
        max_uses: 10,
        use_count: 0,
        conversion_enabled: false,
        email_hint: null,
        status: "active",
        share_url: "https://public.example.test/join#guest=canonical"
      },
      token: "canonical",
      url: "https://public.example.test/join#guest=canonical"
    });
    revokeGuestLink.mockReset().mockResolvedValue({});
    guestLinks.mockReset().mockResolvedValue([]);
  });

  it("uses one canonical URL for the visible link, QR and copy action", async () => {
    const user = userEvent.setup();
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText }
    });
    const api = { createGuestLink, revokeGuestLink, guestLinks } as unknown as ApiClient;

    render(<ConversationShareDialog api={api} conversation={room} onClose={vi.fn()} />);
    expect(
      screen.queryByRole("button", {
        name: "Preauthorize optional account creation"
      })
    ).not.toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Create link and QR" }));

    const expected = "https://public.example.test/join#guest=canonical";
    expect(await screen.findByLabelText("QR value")).toHaveTextContent(expected);
    expect(screen.getByLabelText("Secure guest link")).toHaveValue(expected);

    await user.click(screen.getByRole("button", { name: "Copy link" }));
    await waitFor(() => expect(writeText).toHaveBeenCalledWith(expected));
    expect(screen.getByText("Guest link copied.")).toHaveAttribute("role", "status");
    expect(createGuestLink).toHaveBeenCalledWith(room.id, {
      expires_in_seconds: 86_400,
      max_uses: 10
    });
    expect(
      screen.getByText("Communication-only access. This link does not permit account creation.")
    ).toBeVisible();
  });

  it("keeps conversion opt-in, single-use and limited to authorized owners or admins", async () => {
    const user = userEvent.setup();
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText }
    });
    const verificationCode = "V".repeat(43);
    const privilegedActionStarted = vi.fn();
    const runPrivilegedAction = <T,>(action: () => Promise<T>): Promise<T> => {
      privilegedActionStarted();
      return action();
    };
    createGuestLink.mockResolvedValueOnce({
      guestLink: {
        id: "link-convert",
        conversation_id: room.id,
        expires_at: "2026-07-25T12:00:00Z",
        max_uses: 1,
        use_count: 0,
        conversion_enabled: true,
        email_hint: "j***@example.test",
        status: "active",
        share_url: "https://public.example.test/join#guest=convert"
      },
      token: "convert",
      url: "https://public.example.test/join#guest=convert",
      conversionVerificationCode: verificationCode
    });

    render(
      <ConversationShareDialog
        api={{ createGuestLink, revokeGuestLink, guestLinks } as unknown as ApiClient}
        conversation={room}
        canPreauthorizeAccount
        runPrivilegedAction={runPrivilegedAction}
        onClose={vi.fn()}
      />
    );

    const guestLimit = screen.getByRole("combobox", { name: "Guest limit" });
    await user.selectOptions(guestLimit, "25");
    const conversionToggle = screen.getByRole("button", {
      name: "Preauthorize optional account creation"
    });
    expect(conversionToggle).toHaveAttribute("aria-expanded", "false");
    await user.click(conversionToggle);

    expect(conversionToggle).toHaveAttribute("aria-expanded", "true");
    expect(guestLimit).toBeDisabled();
    expect(guestLimit).toHaveValue("1");
    await user.type(
      screen.getByRole("textbox", { name: "Authorized account email" }),
      "jordan@example.test"
    );
    await user.click(screen.getByRole("button", { name: "Create link and QR" }));

    await waitFor(() =>
      expect(createGuestLink).toHaveBeenCalledWith(room.id, {
        expires_in_seconds: 86_400,
        max_uses: 1,
        conversion_email: "jordan@example.test"
      })
    );
    expect(privilegedActionStarted).toHaveBeenCalledTimes(1);
    expect(
      screen.getByText(
        "Optional account creation is preauthorized for j***@example.test and requires the separate one-time code below."
      )
    ).toBeVisible();
    const code = screen.getByRole("textbox", {
      name: "Account verification code"
    });
    expect(code).toHaveValue(verificationCode);
    expect(code).toHaveAttribute("readonly");
    expect(
      screen.getByText(/It is not contained in the link or QR/)
    ).toBeVisible();
    await user.click(
      screen.getByRole("button", { name: "Copy verification code" })
    );
    await waitFor(() => expect(writeText).toHaveBeenCalledWith(verificationCode));
    expect(writeText).not.toHaveBeenCalledWith(expect.stringContaining("#guest="));
  });

  it("restores the previous guest limit when account preauthorization is turned off", async () => {
    const user = userEvent.setup();
    render(
      <ConversationShareDialog
        api={{ createGuestLink, revokeGuestLink, guestLinks } as unknown as ApiClient}
        conversation={room}
        canPreauthorizeAccount
        onClose={vi.fn()}
      />
    );
    const guestLimit = screen.getByRole("combobox", { name: "Guest limit" });
    await user.selectOptions(guestLimit, "25");
    await user.click(
      screen.getByRole("button", {
        name: "Preauthorize optional account creation"
      })
    );
    await user.click(
      screen.getByRole("button", {
        name: "Use communication-only link"
      })
    );

    expect(guestLimit).toBeEnabled();
    expect(guestLimit).toHaveValue("25");
    expect(
      screen.queryByRole("textbox", { name: "Authorized account email" })
    ).not.toBeInTheDocument();
  });

  it("explains the active-session impact and requires confirmation before revocation", async () => {
    const user = userEvent.setup();
    const api = { createGuestLink, revokeGuestLink, guestLinks } as unknown as ApiClient;

    render(<ConversationShareDialog api={api} conversation={room} onClose={vi.fn()} />);
    await user.click(screen.getByRole("button", { name: "Create link and QR" }));
    await user.click(await screen.findByRole("button", { name: "Revoke" }));

    const confirmation = screen.getByRole("alertdialog", {
      name: "Revoke this guest link?"
    });
    expect(
      screen.getByText(/Active guests admitted through this link will be signed out/i)
    ).toBeVisible();
    expect(screen.getByText(/already created accounts will keep their access/i)).toBeVisible();
    expect(revokeGuestLink).not.toHaveBeenCalled();

    await user.click(
      within(confirmation).getByRole("button", { name: "Cancel" })
    );
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
    expect(revokeGuestLink).not.toHaveBeenCalled();

    await user.click(screen.getByRole("button", { name: "Revoke" }));
    await user.click(
      within(screen.getByRole("alertdialog")).getByRole("button", {
        name: "Revoke guest link"
      })
    );

    await waitFor(() =>
      expect(revokeGuestLink).toHaveBeenCalledWith(room.id, "link-1")
    );
    expect(
      screen.getByText(
        "Guest link revoked. New joins are blocked and active guest sessions were ended."
      )
    ).toHaveAttribute("role", "status");
  });

  it("lists only links the server still classifies as active", async () => {
    guestLinks.mockResolvedValue([
      {
        id: "active-link",
        conversation_id: room.id,
        expires_at: "2026-07-25T12:00:00Z",
        max_uses: 10,
        use_count: 1,
        status: "active"
      },
      {
        id: "expired-link",
        conversation_id: room.id,
        expires_at: "2026-07-23T12:00:00Z",
        max_uses: 10,
        use_count: 1,
        status: "expired"
      },
      {
        id: "exhausted-link",
        conversation_id: room.id,
        expires_at: "2026-07-25T12:00:00Z",
        max_uses: 1,
        use_count: 1,
        status: "exhausted"
      }
    ]);

    render(
      <ConversationShareDialog
        api={{ createGuestLink, revokeGuestLink, guestLinks } as unknown as ApiClient}
        conversation={room}
        onClose={vi.fn()}
      />
    );

    expect(await screen.findByText("1 of 10 guest admissions used")).toBeVisible();
    expect(screen.queryByText("1 of 1 guest admissions used")).not.toBeInTheDocument();
    expect(
      screen.getAllByRole("button", { name: /Revoke guest link expiring/i })
    ).toHaveLength(1);
  });

  it("explains direct-message limits without creating anything", async () => {
    const user = userEvent.setup();
    const direct: Conversation = {
      ...room,
      kind: "direct",
      title: null,
      counterpart_display_name: "Morgan",
      membership_role: "owner"
    };

    render(
      <ConversationShareDialog
        api={{ createGuestLink, guestLinks } as unknown as ApiClient}
        conversation={direct}
        onClose={vi.fn()}
      />
    );

    expect(screen.getByRole("heading", { name: "Create a room to invite a guest" })).toBeVisible();
    expect(screen.getByText(/unavailable for direct messages/i)).toBeVisible();
    expect(createGuestLink).not.toHaveBeenCalled();
    await user.click(screen.getByRole("button", { name: "Got it" }));
    expect(createGuestLink).not.toHaveBeenCalled();
  });
});
