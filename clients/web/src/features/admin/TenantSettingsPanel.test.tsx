import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ApiClient, UpdateTenantInput } from "../../api";
import type { TenantAdministration } from "../../types";
import { TenantSettingsPanel } from "./TenantSettingsPanel";

const runWithStepUp = vi.hoisted(() => vi.fn(<T,>(action: () => Promise<T>) => action()));
vi.mock("../../app/step-up", () => ({
  useStepUp: () => ({ runWithStepUp }),
  stepUpWasCancelled: () => false
}));

const state: TenantAdministration = {
  tenant: { id: "tenant-1", name: "Quota workspace", slug: "quota-workspace", status: "active" },
  settings: {
    tenant_id: "tenant-1",
    allow_audio_calls: true,
    allow_video_calls: true,
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
  beforeEach(() => { runWithStepUp.mockClear(); });

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
      allow_audio_calls: true,
      allow_video_calls: true,
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

  it("converts decimal human units exactly and reviews their impact before a versioned save", async () => {
    const updateTenantAdministration = vi.fn().mockResolvedValue({ ...state, settings: { ...state.settings, message_edit_window_seconds: 150, max_attachment_bytes: 25_123_457, version: 3 } });
    const api = { tenantAdministration: vi.fn().mockResolvedValue(state), updateTenantAdministration } as unknown as ApiClient;
    const onUpdated = vi.fn();
    const user = userEvent.setup();
    render(<TenantSettingsPanel api={api} onUpdated={onUpdated} />);
    await screen.findByRole("heading", { name: "Workspace settings" });
    expect(screen.getByRole("group", { name: "Communication" })).toBeVisible();
    expect(screen.getByRole("group", { name: "Retention" })).toBeVisible();
    expect(screen.getByRole("button", { name: "Save workspace settings" })).toBeDisabled();

    const minutes = screen.getByRole("spinbutton", { name: /^Message edit window \(minutes\)/ });
    const megabytes = screen.getByRole("spinbutton", { name: /^Attachment limit \(MB\)/ });
    expect(minutes).toHaveValue(1440);
    expect(megabytes).toHaveValue(26.2144);
    await user.clear(minutes);
    await user.type(minutes, "2.5");
    await user.clear(megabytes);
    await user.type(megabytes, "25.123457");
    const review = screen.getByRole("region", { name: "Changes to review" });
    expect(within(review).getByRole("status")).toHaveTextContent("Unsaved changes · 2 fields");
    expect(review).toHaveTextContent("existing files are retained");
    expect(updateTenantAdministration).not.toHaveBeenCalled();
    await user.click(screen.getByRole("button", { name: "Save workspace settings" }));

    expect(updateTenantAdministration).toHaveBeenCalledWith(expect.objectContaining({ message_edit_window_seconds: 150, max_attachment_bytes: 25_123_457, version: 2 }));
    expect(runWithStepUp).toHaveBeenCalledOnce();
    expect(onUpdated).toHaveBeenCalledWith(expect.objectContaining({ settings: expect.objectContaining({ version: 3 }) }));
    expect(screen.queryByRole("region", { name: "Changes to review" })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Save workspace settings" })).toBeDisabled();
  });

  it("preserves odd-second and byte limits when editing an unrelated setting", async () => {
    const exactState = { ...state, settings: { ...state.settings, message_edit_window_seconds: 1, max_attachment_bytes: 26_214_401 } };
    const updateTenantAdministration = vi.fn().mockResolvedValue(exactState);
    const api = { tenantAdministration: vi.fn().mockResolvedValue(exactState), updateTenantAdministration } as unknown as ApiClient;
    const user = userEvent.setup();
    render(<TenantSettingsPanel api={api} onUpdated={vi.fn()} />);
    await user.type(await screen.findByRole("textbox", { name: "Workspace name" }), " renamed");
    await user.click(screen.getByRole("button", { name: "Save workspace settings" }));

    expect(updateTenantAdministration).toHaveBeenCalledWith(expect.objectContaining({ message_edit_window_seconds: 1, max_attachment_bytes: 26_214_401, version: 2 }));
  });

  it.each([
    { field: "Message edit window", value: "0.025", units: "seconds" },
    { field: "Attachment limit", value: "25.0000001", units: "bytes" }
  ])("rejects fractional $units before privileged verification and keeps the draft editable", async ({ field, value, units }) => {
    const updateTenantAdministration = vi.fn();
    const api = { tenantAdministration: vi.fn().mockResolvedValue(state), updateTenantAdministration } as unknown as ApiClient;
    const user = userEvent.setup();
    render(<TenantSettingsPanel api={api} onUpdated={vi.fn()} />);
    const input = await screen.findByRole("spinbutton", { name: new RegExp(`^${field}`) });
    await user.clear(input);
    await user.type(input, value);
    await user.click(screen.getByRole("button", { name: "Save workspace settings" }));

    expect(await screen.findByText(`${field}: use a value that represents whole ${units}.`)).toBeVisible();
    expect(updateTenantAdministration).not.toHaveBeenCalled();
    expect(runWithStepUp).not.toHaveBeenCalled();
    expect(input).toHaveValue(Number(value));
    expect(screen.getByRole("button", { name: "Save workspace settings" })).toBeEnabled();
  });

  it.each([1, 1_073_741_824])("preserves valid attachment boundary %i and a long legacy edit window", async (bytes) => {
    const boundaryState = { ...state, settings: { ...state.settings, message_edit_window_seconds: 3_000_001, max_attachment_bytes: bytes } };
    const updateTenantAdministration = vi.fn().mockResolvedValue(boundaryState);
    const api = { tenantAdministration: vi.fn().mockResolvedValue(boundaryState), updateTenantAdministration } as unknown as ApiClient;
    const user = userEvent.setup();
    render(<TenantSettingsPanel api={api} onUpdated={vi.fn()} />);
    await user.type(await screen.findByRole("textbox", { name: "Workspace name" }), " renamed");
    await user.click(screen.getByRole("button", { name: "Save workspace settings" }));

    expect(updateTenantAdministration).toHaveBeenCalledWith(expect.objectContaining({ message_edit_window_seconds: 3_000_001, max_attachment_bytes: bytes }));
  });

  it("shows proposed capacity impact and discards all unsaved changes without an API call", async () => {
    const updateTenantAdministration = vi.fn();
    const api = { tenantAdministration: vi.fn().mockResolvedValue(state), updateTenantAdministration } as unknown as ApiClient;
    const user = userEvent.setup();
    render(<TenantSettingsPanel api={api} onUpdated={vi.fn()} />);
    const identities = await screen.findByRole("spinbutton", { name: /^Maximum active identities/ });
    await user.clear(identities);
    await user.type(identities, "9");
    expect(screen.getByText(/proposed limit is below current usage/)).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Discard changes" }));

    expect(identities).toHaveValue(10);
    expect(screen.queryByRole("region", { name: "Changes to review" })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Save workspace settings" })).toBeDisabled();
    expect(updateTenantAdministration).not.toHaveBeenCalled();
  });

  it("keeps draft values and the original version after a server conflict", async () => {
    const updateTenantAdministration = vi.fn().mockRejectedValue(new Error("Settings changed elsewhere. Reload before saving."));
    const api = { tenantAdministration: vi.fn().mockResolvedValue(state), updateTenantAdministration } as unknown as ApiClient;
    const onUpdated = vi.fn();
    const user = userEvent.setup();
    render(<TenantSettingsPanel api={api} onUpdated={onUpdated} />);
    const minutes = await screen.findByRole("spinbutton", { name: /^Message edit window/ });
    await user.clear(minutes);
    await user.type(minutes, "5");
    await user.click(screen.getByRole("button", { name: "Save workspace settings" }));

    expect(await screen.findByText("Settings changed elsewhere. Reload before saving.")).toBeVisible();
    expect(minutes).toHaveValue(5);
    expect(screen.getByText("Version 2")).toBeVisible();
    expect(updateTenantAdministration).toHaveBeenCalledWith(expect.objectContaining({ version: 2 }));
    expect(onUpdated).not.toHaveBeenCalled();
  });
});
