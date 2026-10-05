import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import { IntegrationsPanel } from "./IntegrationsPanel";

const { runWithStepUp } = vi.hoisted(() => ({ runWithStepUp: <T,>(action: () => Promise<T>) => action() }));

vi.mock("../../app/step-up", () => ({
  useStepUp: () => ({ runWithStepUp }),
  stepUpWasCancelled: () => false
}));

describe("IntegrationsPanel one-time secret handling", () => {
  it("shows pending inventories before presenting a verified empty delivery ledger", async () => {
    let finish!: (value: []) => void;
    const inventory = new Promise<[]>((resolve) => { finish = resolve; });
    const api = { webhooks: vi.fn().mockReturnValue(inventory), webhookDeliveries: vi.fn().mockResolvedValue([]), serviceAccounts: vi.fn().mockResolvedValue([]) } as unknown as ApiClient;
    render(<IntegrationsPanel api={api} />);
    expect(await screen.findByText("Loading webhook deliveries…")).toBeVisible();
    expect(screen.queryByText("No webhook deliveries.")).not.toBeInTheDocument();
    await act(async () => { finish([]); });
    expect(await screen.findByText("No webhook deliveries.")).toBeVisible();
    expect(screen.queryByText("Loading webhook deliveries…")).not.toBeInTheDocument();
    expect(screen.queryByText("0 configured")).not.toBeInTheDocument();
    expect(screen.queryByText("0 recent")).not.toBeInTheDocument();
    expect(screen.queryByRole("combobox", { name: "Delivery endpoint" })).not.toBeInTheDocument();
    expect(screen.queryByRole("combobox", { name: "Delivery status" })).not.toBeInTheDocument();
  });

  it("gives integration-load errors a descriptive dismiss control", async () => {
    const user = userEvent.setup();
    const api = {
      webhooks: vi.fn().mockRejectedValue(new Error("Integrations unavailable")),
      webhookDeliveries: vi.fn().mockResolvedValue([]),
      serviceAccounts: vi.fn().mockResolvedValue([])
    } as unknown as ApiClient;

    render(<IntegrationsPanel api={api} />);

    const dismiss = await screen.findByRole("button", { name: "Dismiss integrations error" });
    expect(screen.getByRole("alert")).toHaveTextContent("Integrations unavailable");
    expect(screen.getByText("Delivery inventory is unavailable. Reload integrations to retry.")).toBeVisible();
    expect(screen.queryByText("No webhook deliveries.")).not.toBeInTheDocument();
    await user.click(dismiss);
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(screen.getByText("Delivery inventory is unavailable. Reload integrations to retry.")).toBeVisible();
    expect(screen.queryByText("Loading webhook deliveries…")).not.toBeInTheDocument();
  });

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

    await user.click(screen.getByText("New webhook"));
    await user.type(screen.getByRole("textbox", { name: "Name" }), "Primary");
    await user.type(screen.getByRole("textbox", { name: "HTTPS URL" }), endpoint.url);
    await user.click(screen.getByRole("checkbox", { name: /Message sent/ }));
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


describe("IntegrationsPanel endpoint management", () => {
  const endpoint = { id: "endpoint-1", name: "Primary", url: "https://hooks.example.test/k-comms", status: "disabled", secret_version: 1, event_types: ["message.created.v1", "custom.existing.v1"], inserted_at: "2026-07-12T10:00:00Z", updated_at: "2026-07-12T10:00:00Z" };
  function makeApi(overrides = {}) { return { webhooks: vi.fn().mockResolvedValue([endpoint]), webhookDeliveries: vi.fn().mockResolvedValue([]), serviceAccounts: vi.fn().mockResolvedValue([]), updateWebhook: vi.fn().mockResolvedValue({ ...endpoint, status: "active" }), ...overrides } as unknown as ApiClient; }

  it("edits name, destination, and events without rotating the secret", async () => {
    const updateWebhook = vi.fn().mockResolvedValue({ ...endpoint, name: "Updated", url: "https://hooks.example.test/new" });
    const api = makeApi({ updateWebhook });
    const user = userEvent.setup();
    render(<IntegrationsPanel api={api} />);
    await user.click(await screen.findByRole("button", { name: "Edit Primary" }));
    const form = screen.getByRole("form", { name: "Edit webhook Primary" });
    expect(within(form).getByRole("checkbox", { name: "custom.existing.v1 custom.existing.v1" })).toBeChecked();
    await user.clear(within(form).getByRole("textbox", { name: "Endpoint name" }));
    await user.type(within(form).getByRole("textbox", { name: "Endpoint name" }), "Updated");
    await user.clear(within(form).getByRole("textbox", { name: "Endpoint HTTPS URL" }));
    await user.type(within(form).getByRole("textbox", { name: "Endpoint HTTPS URL" }), "https://hooks.example.test/new");
    await user.click(within(form).getByRole("checkbox", { name: /Meeting started/ }));
    await user.click(within(form).getByRole("button", { name: "Save endpoint" }));
    await waitFor(() => expect(updateWebhook).toHaveBeenCalledWith("endpoint-1", { name: "Updated", url: "https://hooks.example.test/new", event_types: ["message.created.v1", "custom.existing.v1", "call.started.v1"] }));
    expect(screen.queryByRole("region", { name: "One-time signing secret" })).not.toBeInTheDocument();
  });

  it("reviews re-enabling and preserves secret and failed-delivery semantics", async () => {
    const api = makeApi();
    const user = userEvent.setup();
    render(<IntegrationsPanel api={api} />);
    await user.click(await screen.findByRole("button", { name: "Enable" }));
    const dialog = screen.getByRole("alertdialog", { name: "Enable webhook endpoint?" });
    expect(dialog).toHaveTextContent("Existing failed deliveries are not replayed automatically");
    await user.click(within(dialog).getByRole("button", { name: "Enable endpoint" }));
    await waitFor(() => expect(api.updateWebhook).toHaveBeenCalledWith("endpoint-1", { status: "active" }));
    expect(await screen.findByText("Enabled")).toBeVisible();
  });

  it("keeps failed edits recoverable and leaves endpoint state unchanged", async () => {
    const api = makeApi({ updateWebhook: vi.fn().mockRejectedValue(new Error("Endpoint configuration conflict")) });
    const user = userEvent.setup();
    render(<IntegrationsPanel api={api} />);
    await user.click(await screen.findByRole("button", { name: "Edit Primary" }));
    await user.click(screen.getByRole("button", { name: "Save endpoint" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Endpoint configuration conflict");
    expect(screen.getByRole("form", { name: "Edit webhook Primary" })).toBeVisible();
    expect(screen.getByText("Disabled")).toBeVisible();
  });

  it("shows named delivery failures and blocks replay for disabled endpoints", async () => {
    const api = makeApi({ webhookDeliveries: vi.fn().mockResolvedValue([{ id: "delivery-1", endpoint_id: "endpoint-1", event_type: "message.created.v1", status: "dead_letter", attempt_count: 5, response_status: 503, last_error_code: "http_unavailable", inserted_at: "2026-07-12T10:00:00Z", updated_at: "2026-07-12T10:10:00Z" }]) });
    const user = userEvent.setup();
    render(<IntegrationsPanel api={api} />);
    await user.click(await screen.findByText("Delivery details"));
    expect(screen.getByText("http_unavailable")).toBeVisible();
    expect(screen.getByText("503")).toBeVisible();
    expect(screen.getByRole("button", { name: "Replay" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Copy failure details" })).toBeEnabled();
    expect(screen.queryByText("Live API")).not.toBeInTheDocument();
  });

  it("keeps filters available when their combination has no matches and restores deliveries on reset", async () => {
    const secondary = { ...endpoint, id: "endpoint-2", name: "Secondary" };
    const delivery = { event_type: "message.created.v1", attempt_count: 1, inserted_at: "2026-07-12T10:00:00Z", updated_at: "2026-07-12T10:00:00Z" };
    const api = makeApi({
      webhooks: vi.fn().mockResolvedValue([endpoint, secondary]),
      webhookDeliveries: vi.fn().mockResolvedValue([
        { ...delivery, id: "delivery-1", endpoint_id: endpoint.id, status: "dead_letter" },
        { ...delivery, id: "delivery-2", endpoint_id: secondary.id, status: "delivered" }
      ])
    });
    const user = userEvent.setup();
    render(<IntegrationsPanel api={api} />);
    const endpointFilter = await screen.findByRole("combobox", { name: "Delivery endpoint" });
    const statusFilter = screen.getByRole("combobox", { name: "Delivery status" });
    await user.selectOptions(statusFilter, "dead_letter");
    await user.selectOptions(endpointFilter, secondary.id);

    expect(screen.getByText("No recent deliveries match these filters.")).toBeVisible();
    expect(endpointFilter).toBeVisible();
    expect(statusFilter).toBeVisible();
    expect(screen.getByText("2 recent")).toBeVisible();
    await user.selectOptions(endpointFilter, "");
    expect(screen.queryByText("No recent deliveries match these filters.")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Replay" })).toBeDisabled();
    await user.selectOptions(statusFilter, "");
    expect(screen.getAllByText("Delivery details")).toHaveLength(2);
  });
});
