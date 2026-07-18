import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import { IntegrationsPanel } from "./IntegrationsPanel";

vi.mock("../../app/step-up", () => ({
  useStepUp: () => ({ runWithStepUp: <T,>(action: () => Promise<T>) => action() }),
  stepUpWasCancelled: () => false
}));

describe("IntegrationsPanel one-time secret handling", () => {
  it("blocks another secret-generating operation until the current secret is acknowledged", async () => {
    const endpoint = { id: "endpoint-1", name: "Primary", url: "https://hooks.example.test/k-comms", status: "active", secret_version: 1, event_types: ["message.created.v1"], inserted_at: "2026-07-12T10:00:00Z", updated_at: "2026-07-12T10:00:00Z" };
    const api = {
      webhooks: vi.fn().mockResolvedValue([]),
      webhookDeliveries: vi.fn().mockResolvedValue([]),
      serviceAccounts: vi.fn().mockResolvedValue([]),
      createWebhook: vi.fn().mockResolvedValue({ endpoint, secret: "one-time-secret" })
    } as unknown as ApiClient;
    const user = userEvent.setup();
    render(<IntegrationsPanel api={api} />);

    await user.type(screen.getByRole("textbox", { name: "Name" }), "Primary");
    await user.type(screen.getByRole("textbox", { name: "HTTPS URL" }), endpoint.url);
    await user.type(screen.getByRole("textbox", { name: "Event types" }), "message.created.v1");
    await user.click(screen.getByRole("button", { name: "Create webhook" }));

    expect(await screen.findByText("one-time-secret")).toBeVisible();
    expect(screen.getByRole("button", { name: "Create webhook" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Rotate secret" })).toBeDisabled();
  });

  it("reviews secret rotation and submits the required audit reason", async () => {
    const endpoint = { id: "endpoint-1", name: "Primary", url: "https://hooks.example.test/k-comms", status: "active", secret_version: 1, event_types: ["message.created.v1"], inserted_at: "2026-07-12T10:00:00Z", updated_at: "2026-07-12T10:00:00Z" };
    const rotateWebhookSecret = vi.fn().mockResolvedValue({ endpoint: { ...endpoint, secret_version: 2 }, secret: "rotated-secret" });
    const api = {
      webhooks: vi.fn().mockResolvedValue([endpoint]),
      webhookDeliveries: vi.fn().mockResolvedValue([]),
      serviceAccounts: vi.fn().mockResolvedValue([]),
      rotateWebhookSecret
    } as unknown as ApiClient;
    const user = userEvent.setup();
    render(<IntegrationsPanel api={api} />);

    await user.click(await screen.findByRole("button", { name: "Rotate secret" }));
    expect(screen.getByRole("alertdialog", { name: "Rotate signing secret?" })).toHaveTextContent("Every consumer must be updated");
    await user.type(screen.getByRole("textbox", { name: "Reason for this change" }), "Scheduled rotation");
    await user.click(screen.getByRole("button", { name: "Rotate secret" }));

    await waitFor(() => expect(rotateWebhookSecret).toHaveBeenCalledWith("endpoint-1", "Scheduled rotation"));
    expect(await screen.findByRole("region", { name: "One-time signing secret" })).toHaveTextContent("rotated-secret");
  });
});
