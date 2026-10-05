import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { ApiError } from "../../api";
import type { ApiClient } from "../../api";
import { FederationPanel } from "./FederationPanel";
const room = { id: "room", conversation_id: "conversation", domain: "remote.example.org", residency: "Declared region", status: "active", version: 3, consent: "accepted", remote_cleanup_state: "none" } as const;
function openPanel(container: HTMLElement) { const details = container.querySelector("details")!; details.open = true; fireEvent(details, new Event("toggle")); }
describe("explicit plaintext federation controls", () => {
  it("loads only after opening and renders remote text without interpreting markup", async () => {
    const api = { federationRoom: vi.fn().mockResolvedValue(room), federationTimeline: vi.fn().mockResolvedValue({ events: [{ id: "e", sender: "@person:remote.example.org", body: "<script>private</script>", timestamp: 1, disclosure: "plaintext_bridge" }], cursor: null, remote_deletion_confirmed: false }) } as unknown as ApiClient;
    const { container } = render(<FederationPanel api={api} conversationId="conversation" canManage={false} />);
    expect(api.federationRoom).not.toHaveBeenCalled(); openPanel(container);
    await screen.findByText("Your consent"); fireEvent.click(screen.getByRole("button", { name: "Load remote messages" }));
    await screen.findByText("<script>private</script>"); expect(container.querySelector("script")).toBeNull();
    expect(screen.queryByRole("button", { name: "Send invitation" })).toBeNull();
  });
  it("withdrawal clears remote messages and retains the honest pending cleanup explanation", async () => {
    const api = { federationRoom: vi.fn().mockResolvedValue(room), federationConsent: vi.fn().mockResolvedValue({ ...room, version: 4, consent: "withdrawn", remote_cleanup_state: "pending" }) } as unknown as ApiClient;
    const { container } = render(<FederationPanel api={api} conversationId="conversation" canManage={true} />); openPanel(container);
    fireEvent.click(await screen.findByRole("button", { name: "Withdraw my consent" }));
    await waitFor(() => expect(api.federationConsent).toHaveBeenCalledWith("conversation", 3, false));
    await screen.findByText(/Local redaction or leaving a room cannot prove deletion/);
    expect(screen.queryByRole("button", { name: "Queue plaintext bridge message" })).toBeNull();
  });
  it("definitive current-authority denial clears remote plaintext and hides stale controls", async () => {
    const api = { federationRoom: vi.fn().mockResolvedValue(room), federationTimeline: vi.fn().mockResolvedValue({ events: [{ id: "e", sender: "@person:remote.example.org", body: "private retained remote text", timestamp: 1, disclosure: "plaintext_bridge" }], cursor: null, remote_deletion_confirmed: false }) } as unknown as ApiClient;
    const { container } = render(<FederationPanel api={api} conversationId="conversation" canManage />);
    openPanel(container);
    fireEvent.click(await screen.findByRole("button", { name: "Load remote messages" }));
    await screen.findByText("private retained remote text");
    vi.mocked(api.federationRoom).mockRejectedValue(new ApiError(403, "forbidden", "Access withdrawn"));
    fireEvent.click(screen.getByRole("button", { name: "Reload federation state" }));
    await screen.findByText(/Your access changed/);
    expect(screen.queryByText("private retained remote text")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Queue plaintext bridge message" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Create external room" })).not.toBeInTheDocument();
  });

  it("uncertain sends retry the immutable original UUID and body", async () => {
    const api = { federationRoom: vi.fn().mockResolvedValue(room), sendFederationMessage: vi.fn().mockRejectedValueOnce(new Error("Acknowledgement uncertain")).mockResolvedValueOnce({ id: "command", status: "pending" }) } as unknown as ApiClient;
    const { container } = render(<FederationPanel api={api} conversationId="conversation" canManage />);
    openPanel(container);
    const field = await screen.findByRole("textbox", { name: "Bridge message" });
    fireEvent.change(field, { target: { value: "original uncertain body" } });
    fireEvent.click(screen.getByRole("button", { name: "Queue plaintext bridge message" }));
    await screen.findByText(/previous acknowledgement is uncertain/);
    const original = vi.mocked(api.sendFederationMessage).mock.calls[0]!;
    expect(field).toHaveAttribute("readonly");
    fireEvent.change(field, { target: { value: "synthetic attempted replacement" } });
    fireEvent.click(screen.getByRole("button", { name: "Retry the same bridge message" }));
    await waitFor(() => expect(api.sendFederationMessage).toHaveBeenCalledTimes(2));
    expect(vi.mocked(api.sendFederationMessage).mock.calls[1]).toEqual(original);
    expect(original[2]).toBe("original uncertain body");
    expect(original[3]).toMatch(/^[0-9a-f-]{36}$/);
  });

});
