import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { InstantWorkspaceDraft } from "./InstantWorkspaceDraft";

vi.mock("@excalidraw/excalidraw", () => ({
  Excalidraw: ({
    initialData,
    onChange
  }: {
    initialData?: { elements?: unknown[] };
    onChange?: (elements: unknown[]) => void;
  }) => (
    <div
      data-testid="draft-excalidraw"
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
    mediaActionsAllowed?: boolean;
  } = {}
) {
  return {
    onActivate,
    ...render(
      <InstantWorkspaceDraft
        activating={false}
        error=""
        identityManaged={options.identityManaged ?? false}
        initialDisplayName={options.initialDisplayName}
        mediaActionsAllowed={options.mediaActionsAllowed ?? true}
        retrySeconds={0}
        onActivate={onActivate}
      />
    )
  };
}

describe("InstantWorkspaceDraft", () => {
  beforeEach(() => {
    window.localStorage.clear();
  });

  it("opens as a usable private canvas with an editable generated identity", () => {
    renderDraft();

    expect(
      screen.getByRole("heading", { name: "Message. Draw. Share." })
    ).toBeVisible();
    expect(screen.getByLabelText("Private drawing canvas")).toBeVisible();
    expect(screen.getByLabelText("Workspace messages")).toBeVisible();
    expect(
      (screen.getByRole("textbox", {
        name: "Your display name"
      }) as HTMLInputElement).value
    ).toMatch(/^Guest \d{4}$/);
    expect(screen.getByText("Nothing has been shared yet")).toBeVisible();
  });

  it("promotes the draft scene and first message with stable idempotency keys", async () => {
    const user = userEvent.setup();
    const { onActivate } = renderDraft();

    await user.click(screen.getByRole("button", { name: "Draw rectangle" }));
    await user.type(
      screen.getByRole("textbox", { name: "Message the room" }),
      "Let’s plan this together"
    );
    await user.click(screen.getByRole("button", { name: "Send" }));

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

  it("promotes directly into audio or video call intent", async () => {
    const user = userEvent.setup();
    const { onActivate } = renderDraft();

    await user.click(screen.getByRole("button", { name: "Start audio call" }));
    await user.click(screen.getByRole("button", { name: "Start video call" }));

    expect(onActivate).toHaveBeenNthCalledWith(
      1,
      expect.objectContaining({ intent: "audio-call" })
    );
    expect(onActivate).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({ intent: "video-call" })
    );
  });

  it("keeps call creation unavailable until secure media is verified", () => {
    renderDraft(vi.fn(), { mediaActionsAllowed: false });

    expect(
      screen.getByRole("button", { name: "Start audio call" })
    ).toBeDisabled();
    expect(
      screen.getByRole("button", { name: "Start video call" })
    ).toBeDisabled();
    expect(
      screen.getByText(/trusted HTTPS connection/i)
    ).toBeVisible();
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

    expect(screen.getByTestId("draft-excalidraw")).toHaveAttribute(
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
    await user.click(screen.getByRole("button", { name: "Share" }));
    expect(screen.getByRole("alert")).toHaveTextContent(
      "Enter your display name to continue."
    );
    expect(guestName).toHaveFocus();
  });
});
