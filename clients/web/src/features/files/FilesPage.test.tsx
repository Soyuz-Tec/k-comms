import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Conversation, FileSummary, User } from "../../types";
import { FilesPage } from "./FilesPage";

const conversationId = "11111111-1111-4111-8111-111111111111";
const messageId = "22222222-2222-4222-8222-222222222222";

const conversation: Conversation = {
  id: conversationId,
  tenant_id: "tenant-1",
  kind: "group",
  title: "Finance review",
  counterpart_display_name: null,
  visibility: "private",
  latest_sequence: 42,
  inserted_at: "2026-07-20T09:00:00Z",
  updated_at: "2026-07-24T09:00:00Z"
};

const owner: User = {
  id: "user-2",
  tenant_id: "tenant-1",
  display_name: "Katherine Johnson",
  role: "member",
  status: "active"
};

const availableFile: FileSummary = {
  id: "file-1",
  conversation_id: conversationId,
  message_id: messageId,
  conversation_sequence: 42,
  owner_user_id: owner.id,
  file_name: "forecast.xlsx",
  content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  byte_size: 1_250_000,
  status: "ready",
  scan_status: "clean",
  safety_state: "available",
  downloadable: true,
  uploaded_at: "2026-07-24T10:00:00Z",
  shared_at: "2026-07-24T10:01:00Z",
  inserted_at: "2026-07-24T10:00:00Z",
  updated_at: "2026-07-24T10:01:00Z"
};

const blockedFile: FileSummary = {
  ...availableFile,
  id: "file-2",
  message_id: "33333333-3333-4333-8333-333333333333",
  conversation_sequence: 43,
  file_name: "blocked.exe",
  status: "quarantined",
  scan_status: "blocked",
  safety_state: "blocked",
  downloadable: false
};

const harness = vi.hoisted(() => {
  const files = vi.fn();
  const attachmentDownload = vi.fn();
  return {
    files,
    attachmentDownload,
    api: { files, attachmentDownload }
  };
});

vi.mock("../../app/session", () => ({
  useSession: () => ({
    api: harness.api,
    session: {
      user: { id: "user-1" }
    }
  })
}));

vi.mock("../../app/workspace-data", () => ({
  useWorkspaceData: () => ({
    conversations: [conversation],
    users: [owner]
  })
}));

describe("FilesPage", () => {
  beforeEach(() => {
    harness.files.mockReset().mockResolvedValue({
      data: [availableFile, blockedFile],
      page: { limit: 25, has_more: false, next_cursor: null }
    });
    harness.attachmentDownload.mockReset().mockResolvedValue({
      data: availableFile,
      download: {
        url: "https://objects.example.test/files/forecast.xlsx?signature=short-lived",
        approved_origin: "https://objects.example.test"
      }
    });
  });

  it("shows provenance and deep-links to the exact source message", async () => {
    render(<MemoryRouter initialEntries={["/app/files"]}><FilesPage /></MemoryRouter>);

    const row = (await screen.findByText("forecast.xlsx")).closest("li");
    expect(row).not.toBeNull();
    expect(within(row as HTMLElement).getByText("Finance review")).toBeVisible();
    expect(within(row as HTMLElement).getByText(/Shared by Katherine Johnson/)).toBeVisible();
    expect(within(row as HTMLElement).getByText("Available")).toBeVisible();
    expect(within(row as HTMLElement).getByRole("link", { name: "View source message for forecast.xlsx" })).toHaveAttribute(
      "href",
      `/app?conversation=${conversationId}&search_message=${messageId}&search_sequence=42`
    );

    const blockedDownload = screen.getByRole("button", { name: "Download blocked.exe" });
    expect(blockedDownload).toBeDisabled();
    expect(blockedDownload).toHaveAttribute("title", "This file was blocked by the safety check");
  });

  it("opens only the existing authorized attachment download descriptor", async () => {
    const user = userEvent.setup();
    const replace = vi.fn();
    const close = vi.fn();
    const downloadWindow = {
      close,
      location: { replace },
      opener: window
    } as unknown as Window;
    const open = vi.spyOn(window, "open").mockReturnValue(downloadWindow);
    render(<MemoryRouter><FilesPage /></MemoryRouter>);

    await user.click(await screen.findByRole("button", { name: "Download forecast.xlsx" }));

    await waitFor(() => expect(harness.attachmentDownload).toHaveBeenCalledWith("file-1"));
    expect(open).toHaveBeenCalledWith(
      "about:blank",
      "_blank"
    );
    expect(downloadWindow.opener).toBeNull();
    expect(replace).toHaveBeenCalledWith(
      "https://objects.example.test/files/forecast.xlsx?signature=short-lived",
    );
    expect(close).not.toHaveBeenCalled();
    open.mockRestore();
  });

  it("reports a blocked download window before requesting a signed URL", async () => {
    const user = userEvent.setup();
    const open = vi.spyOn(window, "open").mockReturnValue(null);
    render(<MemoryRouter><FilesPage /></MemoryRouter>);

    await user.click(await screen.findByRole("button", { name: "Download forecast.xlsx" }));

    expect(await screen.findByRole("alert")).toHaveTextContent(
      "Your browser blocked the download window"
    );
    expect(harness.attachmentDownload).not.toHaveBeenCalled();
    open.mockRestore();
  });

  it("closes the placeholder and exposes a dismissible error when download authorization fails", async () => {
    harness.attachmentDownload.mockRejectedValue(new Error("Download authorization expired"));
    const user = userEvent.setup();
    const replace = vi.fn();
    const close = vi.fn();
    const downloadWindow = {
      close,
      location: { replace },
      opener: window
    } as unknown as Window;
    const open = vi.spyOn(window, "open").mockReturnValue(downloadWindow);
    render(<MemoryRouter><FilesPage /></MemoryRouter>);

    const download = await screen.findByRole("button", { name: "Download forecast.xlsx" });
    await user.click(download);

    await waitFor(() => expect(harness.attachmentDownload).toHaveBeenCalledWith("file-1"));
    const error = await screen.findByRole("alert");
    expect(error).toHaveTextContent("Download authorization expired");
    expect(within(error).getByRole("button", { name: "Dismiss download error" })).toBeEnabled();
    expect(close).toHaveBeenCalledOnce();
    expect(replace).not.toHaveBeenCalled();
    await waitFor(() => expect(download).toBeEnabled());

    await user.click(within(error).getByRole("button", { name: "Dismiss download error" }));
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    open.mockRestore();
  });

  it("applies server scopes and keeps failed loads recoverable", async () => {
    const user = userEvent.setup();
    harness.files
      .mockRejectedValueOnce(new Error("File index unavailable"))
      .mockResolvedValue({ data: [], page: { limit: 25, has_more: false, next_cursor: null } });

    render(<MemoryRouter><FilesPage /></MemoryRouter>);
    expect(await screen.findByRole("alert")).toHaveTextContent("File index unavailable");

    await user.click(screen.getByRole("button", { name: "Try again" }));
    expect(await screen.findByText("No shared files yet")).toBeVisible();

    await user.click(screen.getByRole("button", { name: "Shared by me" }));
    await waitFor(() => expect(harness.files).toHaveBeenLastCalledWith({
      scope: "shared_by_me",
      conversation_id: undefined,
      limit: 25,
      cursor: undefined
    }));
  });
});
