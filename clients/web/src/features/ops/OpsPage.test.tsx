import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, useLocation } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { OperationsSnapshot, Session } from "../../types";
import { OpsPage } from "./OpsPage";

const platformOperations = vi.fn<() => Promise<OperationsSnapshot>>();
const testApi = { platformOperations };
function healthySnapshot(): OperationsSnapshot {
  return {
    generated_at: new Date().toISOString(),
    release_revision: "a".repeat(40),
    database: { status: "healthy" },
    queues: [],
    outbox: { pending: 0, published: 20 },
    notifications: {},
    webhooks: {},
    attachments: {},
    providers: { notifications: { status: "ready" }, attachment_scanner: { status: "ready" } }
  };
}
const session: Session = {
  access_token: "access-token",
  refresh_token: "refresh-token",
  token_type: "Bearer",
  expires_in: 900,
  tenant: { id: "tenant-1", name: "Example", slug: "example", status: "active" },
  user: {
    id: "operator-1",
    tenant_id: "tenant-1",
    display_name: "Platform Operator",
    role: "member",
    status: "active",
    platform_role: "platform_operator",
    platform_role_expires_at: "2099-01-01T00:00:00Z"
  },
  device: { id: "device-1", user_id: "operator-1", name: "Browser", platform: "web" }
};

vi.mock("../../app/session", () => ({
  useSession: () => ({ api: testApi, session, setSession: vi.fn() })
}));

describe("OpsPage", () => {
  beforeEach(() => {
    platformOperations.mockReset();
    session.user.platform_role = "platform_operator";
    session.user.platform_role_expires_at = "2099-01-01T00:00:00Z";
  });

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
    const runbooks = screen.getAllByRole("link", { name: /^Open versioned runbook for / });
    expect(runbooks).toHaveLength(5);
    expect(runbooks[0]).toHaveAttribute("href", expect.stringContaining("a".repeat(40)));
    await waitFor(() => expect(platformOperations).toHaveBeenCalled());
  });

  it("keeps healthy conditions and runbooks visible while secondary evidence stays compact", async () => {
    platformOperations.mockResolvedValue(healthySnapshot());
    const user = userEvent.setup();
    render(<MemoryRouter initialEntries={["/ops"]}><OpsPage /></MemoryRouter>);

    expect(await screen.findByText("No action required")).toBeVisible();
    expect(screen.getByText("5 healthy checks")).toBeVisible();
    expect(screen.getByText("The database probe reports healthy.")).toBeVisible();
    expect(screen.getAllByRole("link", { name: /^Open versioned runbook for / })).toHaveLength(5);
    const database = screen.getByText("Authoritative database").closest("details")!;
    expect(database).not.toHaveAttribute("open");
    const queues = screen.getByRole("heading", { name: "Queues", hidden: true }).closest("details")!;
    expect(queues).not.toHaveAttribute("open");
    expect(screen.getByRole("heading", { name: "Pipelines & providers", hidden: true }).closest("details")).not.toHaveAttribute("open");

    await user.click(screen.getByRole("link", { name: "Queues" }));
    expect(queues).toHaveAttribute("open");
    expect(screen.getByText("No platform queue jobs.")).toBeVisible();
    await user.click(database.querySelector("summary")!);
    expect(within(database).getByText("Stop condition")).toBeVisible();
    expect(within(database).getByText("Escalation")).toBeVisible();
  });

  it("opens new problems and stale evidence after refresh, then compacts recovered conditions", async () => {
    const healthy = healthySnapshot();
    const stale = { ...healthy, generated_at: new Date(Date.now() - 180_000).toISOString(), database: { status: "unavailable" } };
    platformOperations.mockResolvedValueOnce(healthy).mockResolvedValueOnce(stale).mockResolvedValueOnce(healthySnapshot());
    const user = userEvent.setup();
    render(<MemoryRouter initialEntries={["/ops"]}><OpsPage /></MemoryRouter>);

    await screen.findByText("No action required");
    await user.click(screen.getByRole("button", { name: "Refresh" }));
    expect(await screen.findByText("2 conditions need review")).toBeVisible();
    expect(screen.getByText("Authoritative database").closest("details")).toHaveAttribute("open");
    expect(screen.getByText("Operations evidence freshness").closest("details")).toHaveAttribute("open");
    expect(screen.getByRole("heading", { name: "Queues" }).closest("details")).toHaveAttribute("open");
    expect(screen.getByRole("heading", { name: "Pipelines & providers" }).closest("details")).toHaveAttribute("open");
    const triageItems = screen.getByRole("region", { name: "Operations triage" }).querySelectorAll(".ops-triage-item");
    expect(triageItems[0]).toHaveTextContent("Authoritative database");

    await user.click(screen.getByRole("button", { name: "Refresh" }));
    await screen.findByText("No action required");
    expect(screen.getByText("Authoritative database").closest("details")).not.toHaveAttribute("open");
    expect(screen.getByText("Operations evidence freshness").closest("details")).not.toHaveAttribute("open");
    expect(screen.getByRole("heading", { name: "Queues", hidden: true }).closest("details")).not.toHaveAttribute("open");
  });

  it("redirects an unauthorized user without issuing a privileged request", async () => {
    session.user.platform_role = null;

    render(
      <MemoryRouter initialEntries={["/ops"]}>
        <OpsPage />
        <LocationProbe />
      </MemoryRouter>
    );

    await waitFor(() => expect(platformOperations).not.toHaveBeenCalled());
    expect(screen.queryByRole("heading", { name: "Service operations" })).not.toBeInTheDocument();
    expect(screen.getByLabelText("location")).toHaveTextContent("/app/");
  });
});

function LocationProbe() {
  const location = useLocation();
  return <output aria-label="location">{location.pathname}</output>;
}
