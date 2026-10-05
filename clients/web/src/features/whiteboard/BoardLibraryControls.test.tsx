import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { BoardLibraryControls } from "./BoardLibraryControls";

const context = vi.hoisted(() => ({ role: "owner", api: { boardAsset: vi.fn(), boardVersions: vi.fn(), exportBoard: vi.fn(), checkpointBoard: vi.fn(), renameBoard: vi.fn(), restoreBoard: vi.fn() } }));
const assetFiles = vi.hoisted(() => ({ loadBoardAssetFile: vi.fn() }));
vi.mock("../../app/session", () => ({ useSession: () => ({ api: context.api, session: { user: { id: "owner" } } }) }));
vi.mock("../../app/workspace-data", () => ({ useOptionalWorkspaceData: () => ({ conversations: [{ id: "conversation", membership_role: context.role }] }) }));
vi.mock("@excalidraw/excalidraw", () => ({ convertToExcalidrawElements: vi.fn() }));
vi.mock("./boardAssetFiles", () => assetFiles);
const version = { id: "checkpoint", label: "Before review", through_sequence: 7, actor_user_id: "owner", inserted_at: "2026-10-04T12:00:00Z" };
const scene = { elements: [], assets: [], title: "Planning", library_version: 2, through_sequence: 9 };

describe("durable board versions and manager changes", () => {
  beforeEach(() => { vi.clearAllMocks(); context.role = "owner"; context.api.boardVersions.mockResolvedValue([version]); context.api.exportBoard.mockResolvedValue(scene); });
  it("saves a named checkpoint using the actual synchronized server sequence", async () => {
    context.api.checkpointBoard.mockResolvedValue(version);
    render(<BoardLibraryControls editor={null} conversationId="conversation" synchronized onRestore={vi.fn()} onArmChanges={vi.fn()} />);
    const user = userEvent.setup(); await user.click(screen.getByRole("button", { name: "Board history & assets" }));
    await screen.findByRole("button", { name: "Restore Before review" });
    await user.type(screen.getByLabelText("Checkpoint name"), "Review");
    await user.click(screen.getByRole("button", { name: "Save checkpoint" }));
    await waitFor(() => expect(context.api.checkpointBoard).toHaveBeenCalledWith("conversation", "Review", 9));
    expect(await screen.findByText("Board checkpoint saved.")).toBeVisible();
  });
  it("requires explicit shared-scene confirmation and preserves a failed restore", async () => {
    context.api.restoreBoard.mockRejectedValue(new Error("stale board version")); const onRestore = vi.fn();
    render(<BoardLibraryControls editor={null} conversationId="conversation" synchronized onRestore={onRestore} onArmChanges={vi.fn()} />);
    const user = userEvent.setup(); await user.click(screen.getByRole("button", { name: "Board history & assets" }));
    await user.click(await screen.findByRole("button", { name: "Restore Before review" }));
    expect(context.api.restoreBoard).not.toHaveBeenCalled();
    await user.click(screen.getByRole("button", { name: "Restore checkpoint" }));
    await waitFor(() => expect(context.api.restoreBoard).toHaveBeenCalledWith("conversation", "checkpoint", 9));
    expect(screen.getByRole("alertdialog")).toHaveTextContent("stale board version");
    expect(onRestore).not.toHaveBeenCalled();
  });
  it("members can checkpoint but manager rename and restore controls stay hidden", async () => {
    context.role = "member";
    render(<BoardLibraryControls editor={null} conversationId="conversation" synchronized onRestore={vi.fn()} onArmChanges={vi.fn()} />);
    await userEvent.setup().click(screen.getByRole("button", { name: "Board history & assets" }));
    await screen.findByText("Before review · Revision 7");
    expect(screen.queryByRole("button", { name: "Rename board" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Restore Before review" })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Save checkpoint" })).toBeVisible();
  });
  it("export reads only active scene assets and preserves approval failures", async () => {
    context.api.exportBoard.mockResolvedValue({ ...scene,
      elements: [{ type: "image", fileId: "visible" }, { type: "image", fileId: "deleted", isDeleted: true }],
      assets: [{ id: "unused" }, { id: "deleted" }, { id: "visible" }]
    });
    assetFiles.loadBoardAssetFile.mockRejectedValue(new Error("Source image is no longer available"));
    render(<BoardLibraryControls editor={null} conversationId="conversation" synchronized onRestore={vi.fn()} onArmChanges={vi.fn()} />);
    const user = userEvent.setup(); await user.click(screen.getByRole("button", { name: "Board history & assets" }));
    await screen.findByRole("button", { name: "Restore Before review" });
    await user.click(screen.getByRole("button", { name: "Export board scene" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Source image is no longer available");
    expect(assetFiles.loadBoardAssetFile).toHaveBeenCalledExactlyOnceWith(context.api, "conversation", "visible", undefined);
    expect(screen.getByRole("button", { name: "Export board scene" })).toBeEnabled();
  });
});
