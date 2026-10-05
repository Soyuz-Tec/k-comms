import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
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
});
