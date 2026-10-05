import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { VerificationRequest } from "matrix-js-sdk/lib/crypto-api";
import { PrivateRoomsPage } from "./PrivateRoomsPage";
import type { PrivateRoom } from "./types";

const harness = vi.hoisted(() => ({
  api: {
    directoryUsers: vi.fn(),
    privateRoomApi: {
      privateRooms: vi.fn(), privateRoom: vi.fn(), createPrivateRoom: vi.fn(),
      matrixUploadPublicSigningKeys: vi.fn(), removePrivateMember: vi.fn()
    }
  },
  runtime: {
    unlock: vi.fn(), close: vi.fn(), select: vi.fn(), devices: vi.fn(), verify: vi.fn(),
    prepareRecovery: vi.fn(), confirmRecoverySaved: vi.fn(), recover: vi.fn(),
    loadEarlier: vi.fn(), send: vi.fn(),
    publicDevice: () => ({ userId: "@ada:example.test", deviceId: "SYNTHETIC" })
  },
  callbacks: null as null | { verification: (request: VerificationRequest) => void },
  runWithStepUp: (operation: () => Promise<unknown>) => operation()
}));

vi.mock("../../app/session", () => ({ useSession: () => ({
  api: harness.api,
  session: { tenant: { id: "tenant-1" }, user: { id: "user-1", display_name: "Ada" }, device: { id: "device-1" } }
}) }));
vi.mock("../../app/step-up", () => ({ useStepUp: () => ({ runWithStepUp: harness.runWithStepUp }) }));
vi.mock("./MatrixPrivateClient", () => ({ MatrixPrivateClient: class {
  constructor(...args: unknown[]) {
    harness.callbacks = args[3] as typeof harness.callbacks;
    return harness.runtime;
  }
} }));

const room: PrivateRoom = {
  id: "room-1", tenant_id: "tenant-1", title: "Sample private room", matrix_room_id: "!room:example.test",
  control_matrix_user_id: "@control:example.test", state: "active", membership_epoch: 2, generation: 1,
  role: "owner", members: [{ tenant_id: "tenant-1", user_id: "user-2", issuer: "https://example.test", matrix_user_id: "@grace:example.test", provisioning_state: "ready" }]
};

function openPage(path = "/app/private") {
  return render(<MemoryRouter initialEntries={[path]}><PrivateRoomsPage /></MemoryRouter>);
}
async function unlock(user: ReturnType<typeof userEvent.setup>) {
  await user.type(screen.getByLabelText("Local crypto-store password", { exact: true }), "synthetic-store-password");
  await user.click(screen.getByRole("button", { name: "Unlock encrypted device" }));
  await screen.findByRole("button", { name: "Lock device" });
}

beforeEach(() => {
  vi.clearAllMocks(); harness.callbacks = null;
  harness.api.directoryUsers.mockResolvedValue({ data: [{ id: "user-2", display_name: "Grace" }] });
  harness.api.privateRoomApi.privateRooms.mockResolvedValue([room]);
  harness.api.privateRoomApi.privateRoom.mockResolvedValue(room);
  harness.runtime.unlock.mockResolvedValue(undefined);
  harness.runtime.close.mockResolvedValue(undefined);
  harness.runtime.select.mockResolvedValue(undefined);
  harness.runtime.devices.mockResolvedValue(["PEER"]);
  harness.runtime.verify.mockResolvedValue(undefined);
  harness.runtime.prepareRecovery.mockResolvedValue("synthetic-recovery-key");
  harness.runtime.confirmRecoverySaved.mockResolvedValue(undefined);
});

describe("private room task guidance", () => {
  it("distinguishes loading and failed room inventory from an empty workspace", async () => {
    let reject!: (error: Error) => void;
    harness.api.privateRoomApi.privateRooms.mockReturnValueOnce(new Promise((_, fail) => { reject = fail; }));
    openPage();
    expect(screen.getByRole("status")).toHaveTextContent("Loading private rooms…");
    expect(screen.queryByText(/No private rooms yet/)).not.toBeInTheDocument();
    act(() => reject(new Error("Private rooms unavailable.")));
    await screen.findByRole("alert");
    expect(screen.getByText("Your room list could not be loaded.")).toBeVisible();
    expect(screen.queryByText(/No private rooms yet/)).not.toBeInTheDocument();
  });

  it("keeps room actions locked and discloses metadata and incomplete erasure", async () => {
    const user = userEvent.setup(); openPage();
    const roomButton = await screen.findByRole("button", { name: /Sample private room/ });
    expect(roomButton).toBeDisabled();
    expect(screen.getByText(/Room titles, membership and timing remain visible/)).toBeVisible();
    expect(screen.getByText(/Backup and device-key erasure is not confirmed/)).toBeVisible();
    expect(screen.getByLabelText("Private room setup steps")).toHaveTextContent("Verify everyone in your room");
    expect(screen.getByLabelText("Local crypto-store password", { exact: true })).toHaveAttribute("minLength", "12");
    expect(screen.getByText(/This protects this browser's encrypted store and stays on this device/)).toBeVisible();
    expect(screen.getByText(/K-Comms cannot recover it for you/)).toBeVisible();
    expect(screen.queryByRole("region", { name: "Encrypted conversation" })).not.toBeInTheDocument();
    await user.click(screen.getByText("Create a new encrypted room"));
    expect(screen.getByRole("button", { name: "Create encrypted room" })).toBeDisabled();
    expect(harness.runtime.unlock).not.toHaveBeenCalled();
  });

  it("shows empty room inventory while locked and offers conversation guidance after unlocking", async () => {
    harness.api.privateRoomApi.privateRooms.mockResolvedValueOnce([]);
    const user = userEvent.setup(); openPage();
    expect(await screen.findByText("No private rooms yet.")).toBeVisible();
    expect(screen.queryByRole("region", { name: "Encrypted conversation" })).not.toBeInTheDocument();
    await unlock(user);
    const conversation = screen.getByRole("region", { name: "Encrypted conversation" });
    expect(conversation).toHaveTextContent("Verify every participant before you send a message.");
    await user.click(screen.getByRole("button", { name: "Lock device" }));
    await screen.findByRole("button", { name: "Unlock encrypted device" });
    expect(screen.queryByRole("region", { name: "Encrypted conversation" })).not.toBeInTheDocument();
    expect(screen.getByText("No private rooms yet.")).toBeVisible();
  });

  it("opens the requested room only after unlocking and uses exact selected identities for verification", async () => {
    const user = userEvent.setup(); openPage("/app/private?room=room-1");
    await screen.findByRole("button", { name: /Sample private room/ });
    await unlock(user);
    expect(harness.runtime.unlock).toHaveBeenCalledWith("synthetic-store-password");
    expect(harness.runtime.select).toHaveBeenCalledWith(room);
    await screen.findByLabelText("Encrypted message", { exact: true });
    await user.click(screen.getByText("Verify participants and other devices"));
    await user.selectOptions(screen.getByLabelText("Participant", { exact: true }), "@grace:example.test");
    await waitFor(() => expect(screen.getByRole("button", { name: "Request SAS verification" })).toBeEnabled());
    await user.click(screen.getByRole("button", { name: "Request SAS verification" }));
    expect(harness.runtime.verify).toHaveBeenCalledWith("@grace:example.test", "PEER");
  });

  it("requires the saved-key action before finishing recovery setup", async () => {
    const user = userEvent.setup(); openPage(); await unlock(user);
    await user.click(screen.getByText("Set up or recover encryption"));
    await user.click(screen.getByRole("button", { name: "Set up a new identity and recovery key" }));
    expect(await screen.findByLabelText("Save this recovery key securely", { exact: true })).toHaveValue("synthetic-recovery-key");
    expect(harness.runtime.confirmRecoverySaved).not.toHaveBeenCalled();
    await user.click(screen.getByRole("button", { name: "I saved the key; finish setup" }));
    await waitFor(() => expect(harness.runtime.confirmRecoverySaved).toHaveBeenCalledOnce());
    expect(screen.queryByLabelText("Save this recovery key securely", { exact: true })).not.toBeInTheDocument();
  });

  it("explains device-store removal and requires confirmation before forgetting keys", async () => {
    const user = userEvent.setup(); openPage(); await unlock(user);
    await user.click(screen.getByText("Device details and key removal"));
    await user.click(screen.getByRole("button", { name: "Lock and forget device keys" }));
    const confirmation = screen.getByRole("alertdialog", { name: "Forget this device's encryption keys?" });
    expect(confirmation).toHaveTextContent("does not prove deletion of provider backups");
    expect(harness.runtime.close).not.toHaveBeenCalledWith(true);
    await user.click(within(confirmation).getByRole("button", { name: "Lock and forget device keys" }));
    await waitFor(() => expect(harness.runtime.close).toHaveBeenCalledWith(true));
    await screen.findByRole("button", { name: "Unlock encrypted device" });
  });

  it("isolates verification in the shared modal and cancels the exact request on Escape", async () => {
    const user = userEvent.setup(); openPage(); await unlock(user);
    const cancel = vi.fn().mockResolvedValue(undefined);
    const request = { otherUserId: "@grace:example.test", otherDeviceId: "PEER", cancel } as unknown as VerificationRequest;
    act(() => harness.callbacks!.verification(request));
    const dialog = screen.getByRole("dialog", { name: "Verify encryption identity" });
    expect(dialog).toHaveTextContent("Compare the symbols (SAS) directly");
    expect(screen.queryByRole("button", { name: "Lock device" })).not.toBeInTheDocument();
    await user.keyboard("{Escape}");
    expect(cancel).toHaveBeenCalledOnce();
    expect(screen.queryByRole("dialog", { name: "Verify encryption identity" })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Lock device" })).toBeVisible();
  });
});
