import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { OperationsSnapshot } from "../../types";
import { OpsPage } from "./OpsPage";

const platformOperations = vi.fn<() => Promise<OperationsSnapshot>>();
const session = {
  access_token: "access-token",
  refresh_token: "refresh-token",
  token_type: "Bearer",
  expires_in: 900,
  tenant: { id: "tenant-1", name: "Example", slug: "example", status: "active" },
  user: {
    id: "operator-1",
    tenant_id: "tenant-1",
    display_name: "Platform Operator",
    role: "member" as const,
    status: "active",
    platform_role: "platform_operator" as const,
    platform_role_expires_at: "2099-01-01T00:00:00Z"
  },
  device: { id: "device-1", user_id: "operator-1", name: "Browser", platform: "web" }
};

vi.mock("../../app/session", () => ({
  useSession: () => ({ api: { platformOperations }, session, setSession: vi.fn() })
}));

describe("OpsPage", () => {
  beforeEach(() => platformOperations.mockReset());

  it("shows an actionable content-blind triage contract for degraded evidence", async () => {
    platformOperations.mockResolvedValue({
      generated_at: new Date().toISOString(),
      release_revision: "a".repeat(40),
      database: { status: "unavailable" },
      queues: [{ queue: "events", state: "retryable", count: 12, oldest_scheduled_at: new Date(Date.now() - 901_000).toISOString() }],
      outbox: { pending: 1_001, published: 20 },
      notifications: { failed: 2 },
      webhooks: {},
      attachments: { failed: 1 },
      providers: { notifications: { status: "unavailable" }, attachment_scanner: { status: "ready" } }
    });

    render(<MemoryRouter initialEntries={["/ops"]}><OpsPage /></MemoryRouter>);

    expect(await screen.findByRole("heading", { name: "Operations triage" })).toBeVisible();
    expect(screen.getByText("Authoritative database")).toBeVisible();
    expect(screen.getByText("Queue and outbox delay")).toBeVisible();
    expect(screen.getByText("Notification and webhook delivery")).toBeVisible();
    expect(screen.getByText("Attachment safety pipeline")).toBeVisible();
    expect(screen.getAllByText("Stop condition").length).toBeGreaterThan(0);
    expect(screen.getAllByText("Escalation").length).toBeGreaterThan(0);
    expect(screen.getByText(/Runbooks are bound to release a{12}\./)).toBeVisible();
    const runbooks = screen.getAllByRole("link", { name: "Open versioned runbook" });
    expect(runbooks).toHaveLength(5);
    expect(runbooks[0]).toHaveAttribute("href", expect.stringContaining("a".repeat(40)));
    await waitFor(() => expect(platformOperations).toHaveBeenCalled());
  });
});
