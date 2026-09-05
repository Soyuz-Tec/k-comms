import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { InstantWorkspaceDraft } from "./InstantWorkspaceDraft";

vi.mock("../whiteboard/KCommsDrawingCanvas", () => ({
  KCommsDrawingCanvas: ({
    initialData,
    onChange
  }: {
    initialData?: { elements?: unknown[] };
    onChange?: (elements: unknown[]) => void;
  }) => (
    <div
      data-testid="draft-drawing-surface"
      data-elements={initialData?.elements?.length || 0}
    >
      <button
        type="button"
        onClick={() =>
          onChange?.([
            {
              id: "shape-1",
              type: "rectangle",
              version: 1,
              versionNonce: 7,
              isDeleted: false
            }
          ])
        }
      >
        Draw rectangle
      </button>
    </div>
  )
}));

function renderDraft(
  onActivate = vi.fn().mockResolvedValue(true),
  options: {
    identityManaged?: boolean;
    initialDisplayName?: string;
  } = {}
) {
  return {
    onActivate,
    ...render(
      <MemoryRouter>
        <InstantWorkspaceDraft
          activating={false}
          error=""
          identityManaged={options.identityManaged ?? false}
          initialDisplayName={options.initialDisplayName}
          retrySeconds={0}
          onActivate={onActivate}
        />
      </MemoryRouter>
    )
  };
}

describe("InstantWorkspaceDraft", () => {
  beforeEach(() => {
    window.localStorage.clear();
  });

  it("opens as a usable local canvas with room creation as the next step", () => {
    renderDraft();

    expect(
      screen.getByRole("heading", { name: "Message. Draw. Share." })
    ).toHaveClass("sr-only");
    expect(screen.getByLabelText("Local drawing canvas")).toBeVisible();
    expect(screen.getByLabelText("Room setup")).toBeVisible();
    expect(
      (screen.getByRole("textbox", {
        name: "Your display name"
      }) as HTMLInputElement).value
    ).toMatch(/^Guest \d{4}$/);
    expect(screen.getByText("Your name", { exact: false }).closest("li")).toHaveAttribute("aria-current", "step");
    expect(screen.getByRole("button", { name: "Create room" })).toBeVisible();
    const firstMessage = screen.getByRole("textbox", {
      name: "Optional first message"
    });
    const firstMessageShell = firstMessage.closest(".composer-shell");
    const createAndSend = screen.getByRole("button", {
      name: "Create & send"
    });
    expect(firstMessageShell).toBeVisible();
    expect(firstMessageShell).toContainElement(createAndSend);
    expect(screen.getByRole("link", { name: /sign in/i })).toHaveAttribute(
      "href",
      "/sign-in"
    );
  });

  it("promotes the draft scene and first message with stable idempotency keys", async () => {
    const user = userEvent.setup();
    const { onActivate } = renderDraft();

    await user.click(screen.getByRole("button", { name: "Draw rectangle" }));
    await user.type(
      screen.getByRole("textbox", { name: "Optional first message" }),
      "Let’s plan this together"
    );
    await user.keyboard("{Enter}");

    await waitFor(() => expect(onActivate).toHaveBeenCalledOnce());
    expect(onActivate).toHaveBeenCalledWith(
      expect.objectContaining({
        displayName: expect.stringMatching(/^Guest \d{4}$/),
        elements: [expect.objectContaining({ id: "shape-1" })],
        initialMessage: "Let’s plan this together",
        intent: "message",
        messageClientId: expect.stringMatching(/^[0-9a-f-]{36}$/i),
        whiteboardOperationId: expect.stringMatching(/^[0-9a-f-]{36}$/i)
      })
    );
  });

  it("keeps invite and call actions behind room creation", async () => {
    const user = userEvent.setup();
    const { onActivate } = renderDraft();

    expect(screen.queryByRole("button", { name: "Share" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Start audio call" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Start video call" })).not.toBeInTheDocument();
    expect(screen.getByText(/Invite links, QR sharing, audio, and video appear inside the room/i)).toBeVisible();

    await user.click(screen.getByRole("button", { name: "Create room" }));
    expect(onActivate).toHaveBeenCalledWith(
      expect.objectContaining({ intent: "room" })
    );
  });

  it("restores a private canvas draft after the component is reopened", async () => {
    const user = userEvent.setup();
    const first = renderDraft();
    await user.click(screen.getByRole("button", { name: "Draw rectangle" }));

    await waitFor(() =>
      expect(
        window.localStorage.getItem("k-comms.instant-workspace-draft.v1")
      ).toContain("shape-1")
    );
    first.unmount();
    renderDraft();

    expect(screen.getByTestId("draft-drawing-surface")).toHaveAttribute(
      "data-elements",
      "1"
    );
  });

  it("keeps a signed-in identity managed and focuses an empty guest identity", async () => {
    const managed = renderDraft(vi.fn(), {
      identityManaged: true,
      initialDisplayName: "Taylor Member"
    });
    const managedName = screen.getByRole("textbox", {
      name: "Your display name"
    });
    expect(managedName).toHaveValue("Taylor Member");
    expect(managedName).toBeDisabled();
    managed.unmount();

    const user = userEvent.setup();
    renderDraft();
    const guestName = screen.getByRole("textbox", {
      name: "Your display name"
    });
    await user.clear(guestName);
    await user.click(screen.getByRole("button", { name: "Create room" }));
    expect(screen.getByRole("alert")).toHaveTextContent(
      "Enter your display name to continue."
    );
    expect(guestName).toHaveFocus();
  });

  it("requires confirmation before clearing local work", async () => {
    const user = userEvent.setup();
    renderDraft();
    await user.type(
      screen.getByRole("textbox", { name: "Room name" }),
      "Planning room"
    );

    await user.click(screen.getByRole("button", { name: "Clear local draft" }));
    const dialog = screen.getByRole("dialog", { name: "Clear this local draft?" });
    expect(dialog).toBeVisible();
    await waitFor(() =>
      expect(screen.getByRole("button", { name: "Cancel" })).toHaveFocus()
    );
    expect(document.getElementById("instant-draft-room-title")).toHaveValue(
      "Planning room"
    );

    await user.click(within(dialog).getByRole("button", { name: "Clear local draft" }));
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    expect(screen.getByRole("textbox", { name: "Room name" })).toHaveValue("");
  });
});
