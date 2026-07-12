import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { ApiClient, UpdateTenantInput } from "../../api";
import type { TenantAdministration } from "../../types";
import { TenantSettingsPanel } from "./TenantSettingsPanel";

const runWithStepUp = vi.hoisted(() => <T,>(action: () => Promise<T>) => action());
vi.mock("../../app/step-up", () => ({
  useStepUp: () => ({ runWithStepUp }),
  stepUpWasCancelled: () => false
}));

const state: TenantAdministration = {
  tenant: { id: "tenant-1", name: "Quota workspace", slug: "quota-workspace", status: "active" },
  settings: {
    tenant_id: "tenant-1",
    allow_public_channels: true,
    message_edit_window_seconds: 86_400,
    max_attachment_bytes: 26_214_400,
    default_retention_days: 365,
    max_active_users: 10,
    max_active_conversations: 20,
    max_conversation_members: 5,
    version: 2
  },
  usage: {
    active_users: 11,
    active_conversations: 7,
    largest_conversation_members: 4,
    limits: { max_active_users: 10, max_active_conversations: 20, max_conversation_members: 5 },
    at_capacity: { active_users: false, active_conversations: false, conversation_members: false, any: false },
    over_limit: { active_users: true, active_conversations: false, conversation_members: false, any: true }
  }
};

describe("TenantSettingsPanel", () => {
  it("announces quota usage and submits all admission limits accessibly", async () => {
    const updateTenantAdministration = vi.fn<(input: UpdateTenantInput) => Promise<TenantAdministration>>().mockResolvedValue({
      ...state,
      settings: { ...state.settings, max_active_users: 12, version: 3 },
      usage: {
        ...state.usage,
        limits: { ...state.usage.limits, max_active_users: 12 },
        at_capacity: { ...state.usage.at_capacity, active_users: false, any: false },
        over_limit: { ...state.usage.over_limit, active_users: false, any: false }
      }
    });
    const api = {
      tenantAdministration: vi.fn().mockResolvedValue(state),
      updateTenantAdministration
    } as unknown as ApiClient;
    const user = userEvent.setup();

    render(<TenantSettingsPanel api={api} onUpdated={vi.fn()} />);

    expect(await screen.findByRole("heading", { name: "Capacity usage" })).toBeVisible();
    expect(screen.getByRole("alert")).toHaveTextContent("new admissions are blocked");
    expect(screen.getByText("11 of 10")).toBeVisible();
    expect(screen.getByText("7 of 20")).toBeVisible();
    expect(screen.getByText("4 of 5")).toBeVisible();

    const activeUsers = screen.getByRole("spinbutton", { name: /Maximum active identities/ });
    await user.clear(activeUsers);
    await user.type(activeUsers, "12");
    await user.click(screen.getByRole("button", { name: "Save workspace settings" }));

    expect(updateTenantAdministration).toHaveBeenCalledWith(expect.objectContaining({
      max_active_users: 12,
      max_active_conversations: 20,
      max_conversation_members: 5,
      version: 2
    }));
    expect(await screen.findByText("Workspace settings updated.")).toBeVisible();
  });

  it("announces exact capacity separately from an over-limit state", async () => {
    const atCapacity: TenantAdministration = {
      ...state,
      usage: {
        ...state.usage,
        active_users: 10,
        at_capacity: { ...state.usage.at_capacity, active_users: true, any: true },
        over_limit: { ...state.usage.over_limit, active_users: false, any: false }
      }
    };
    const api = { tenantAdministration: vi.fn().mockResolvedValue(atCapacity) } as unknown as ApiClient;

    render(<TenantSettingsPanel api={api} onUpdated={vi.fn()} />);

    expect(await screen.findByText("At capacity")).toBeVisible();
    expect(screen.getByRole("status")).toHaveTextContent("next admission");
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });
});
