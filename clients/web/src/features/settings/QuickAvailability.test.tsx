import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "../../api/errors";
import type { Availability, UpdateAvailability } from "../../types/enterpriseIdentity";
import { PersonalAvailability } from "./QuickAvailability";

const mocks = vi.hoisted(() => ({
  api: { availability: vi.fn(), updateAvailability: vi.fn() },
  session: { tenant: { id: "tenant-1" }, user: { id: "user-1", role: "member", version: 1 }, device: { id: "device-1" }, access_token: "access" }
}));
vi.mock("../../app/session", () => ({ useSession: () => ({ api: mocks.api, session: mocks.session }) }));
const available: Availability = { status: "available", presence_state: "available", presence_expires_at: null, dnd_until: null, dnd_schedule: {}, dnd_active: false, retry_at: null, timezone: "America/New_York" };
const schedule = { days: [1, 2, 3, 4, 5], start: "22:00", end: "08:00" };
const view = () => <MemoryRouter><PersonalAvailability /></MemoryRouter>;

beforeEach(() => {
  mocks.session.access_token = "access";
  mocks.session.user.id = "user-1";
  mocks.session.user.role = "member";
  mocks.session.user.version = 1;
  mocks.api.availability.mockReset().mockResolvedValue(available);
  mocks.api.updateAvailability.mockReset().mockImplementation(async (input: UpdateAvailability) => ({ ...available, ...input, status: input.presence_state, dnd_active: input.presence_state === "dnd", retry_at: input.presence_state === "dnd" ? input.presence_expires_at : null }));
  window.localStorage.clear();
});
afterEach(() => vi.useRealTimers());

describe("quick persistent availability", () => {
  it("pauses notifications for the selected duration and preserves the latest weekly policy", async () => {
    const user = userEvent.setup();
    render(view());
    await screen.findByRole("combobox", { name: "Set status" });
    mocks.api.availability.mockResolvedValue({ ...available, dnd_schedule: schedule });
    await user.selectOptions(screen.getByRole("combobox", { name: "Status duration" }), "30");
    const started = Date.now();
    await user.click(screen.getByRole("button", { name: "Pause notifications" }));
    await screen.findByText("Do not disturb saved.");
    expect(mocks.api.updateAvailability).toHaveBeenCalledOnce();
    const input = mocks.api.updateAvailability.mock.calls[0]?.[0] as UpdateAvailability;
    expect(input).toMatchObject({ presence_state: "dnd", dnd_until: null, dnd_schedule: schedule });
    expect(Date.parse(input.presence_expires_at!) - started).toBeGreaterThanOrEqual(30 * 60_000);
    expect(Date.parse(input.presence_expires_at!) - started).toBeLessThan(30 * 60_000 + 2000);
    expect(screen.getByText(/America\/New_York/)).toBeVisible();
    expect(screen.getByRole("link", { name: "Schedule and notification settings" })).toHaveAttribute("href", "/app/you?section=notifications");
    expect(window.localStorage.getItem("k-comms.availability-changed.v1")).toMatch(/^\d+$/);
  });

  it("clears manual overrides without disabling an active weekly schedule", async () => {
    const dnd = { ...available, status: "dnd", presence_state: "dnd", dnd_active: true, dnd_schedule: schedule };
    mocks.api.availability.mockResolvedValue(dnd);
    mocks.api.updateAvailability.mockResolvedValue({ ...dnd, presence_state: "available" });
    render(view());
    await userEvent.setup().click(await screen.findByRole("button", { name: "Clear manual status" }));
    expect(await screen.findByText("Manual status cleared. Your weekly do not disturb schedule is still active.")).toBeVisible();
    expect(mocks.api.updateAvailability).toHaveBeenCalledWith({ presence_state: "available", presence_expires_at: null, dnd_until: null, dnd_schedule: schedule });
    expect(screen.getByRole("combobox", { name: "Set status" })).toHaveValue("dnd");
  });

  it("offers a permanent status and retains current server status when a save fails", async () => {
    const user = userEvent.setup();
    mocks.api.updateAvailability.mockRejectedValue(new Error("Policy unavailable"));
    render(view());
    await user.selectOptions(await screen.findByRole("combobox", { name: "Status duration" }), "0");
    await user.selectOptions(screen.getByRole("combobox", { name: "Set status" }), "busy");
    expect(await screen.findByRole("alert")).toHaveTextContent("Policy unavailable");
    expect(mocks.api.updateAvailability).toHaveBeenCalledWith({ presence_state: "busy", presence_expires_at: null, dnd_until: null, dnd_schedule: {} });
    expect(screen.getByRole("combobox", { name: "Set status" })).toHaveValue("available");
    expect(screen.queryByText("Busy saved.")).not.toBeInTheDocument();
  });

  it("refreshes cross-tab invalidations and focus without storing profile or policy data", async () => {
    render(view());
    await screen.findByRole("combobox", { name: "Set status" });
    mocks.api.availability.mockResolvedValue({ ...available, status: "away", presence_state: "away" });
    fireEvent(window, new StorageEvent("storage", { key: "k-comms.availability-changed.v1", newValue: "changed" }));
    await waitFor(() => expect(screen.getByRole("combobox", { name: "Set status" })).toHaveValue("away"));
    mocks.api.availability.mockResolvedValue(available);
    fireEvent.focus(window);
    await waitFor(() => expect(screen.getByRole("combobox", { name: "Set status" })).toHaveValue("available"));
    expect(window.localStorage.length).toBe(0);
  });

  it("rechecks status when its duration expires", async () => {
    vi.useFakeTimers();
    const until = new Date(Date.now() + 1000).toISOString();
    mocks.api.availability.mockResolvedValue({ ...available, status: "busy", presence_state: "busy", presence_expires_at: until });
    await act(async () => { render(view()); });
    expect(screen.getByRole("combobox", { name: "Set status" })).toHaveValue("busy");
    mocks.api.availability.mockResolvedValue({ ...available, presence_state: "busy", presence_expires_at: until });
    await act(async () => { await vi.advanceTimersByTimeAsync(1100); });
    expect(screen.getByRole("combobox", { name: "Set status" })).toHaveValue("available");
    expect(document.querySelector(".quick-availability-current time")).not.toBeInTheDocument();
  });

  it("clears private state on authority rejection and can retry", async () => {
    render(view());
    await screen.findByRole("combobox", { name: "Set status" });
    mocks.api.availability.mockRejectedValue(new ApiError(403, "forbidden", "Access changed"));
    fireEvent.focus(window);
    expect(await screen.findByRole("alert")).toHaveTextContent("Access changed");
    expect(screen.queryByRole("combobox", { name: "Set status" })).not.toBeInTheDocument();
    mocks.api.availability.mockResolvedValue(available);
    await userEvent.setup().click(screen.getByRole("button", { name: "Retry availability" }));
    expect(await screen.findByRole("combobox", { name: "Set status" })).toHaveValue("available");
  });

  it("does not turn a distant expiry into an immediate refresh loop", async () => {
    vi.useFakeTimers();
    mocks.api.availability.mockResolvedValue({ ...available, status: "dnd", presence_state: "dnd", dnd_active: true, retry_at: new Date(Date.now() + 60 * 24 * 60 * 60_000).toISOString() });
    await act(async () => { render(view()); });
    await act(async () => { await vi.advanceTimersByTimeAsync(1000); });
    expect(mocks.api.availability).toHaveBeenCalledOnce();
  });

  it("hides retained availability immediately when known authority changes", async () => {
    const { rerender } = render(view());
    await screen.findByRole("combobox", { name: "Set status" });
    mocks.api.availability.mockReturnValue(new Promise(() => {}));
    mocks.session.user.role = "moderator";
    mocks.session.user.version += 1;
    rerender(view());
    expect(screen.queryByRole("combobox", { name: "Set status" })).not.toBeInTheDocument();
    expect(screen.getByRole("status")).toHaveTextContent("Checking availability");
  });

  it("replaces retained status with an offline state and rechecks on reconnect", async () => {
    render(view());
    await screen.findByRole("combobox", { name: "Set status" });
    fireEvent(window, new Event("offline"));
    expect(screen.getByRole("alert")).toHaveTextContent("You are offline");
    expect(screen.queryByRole("button", { name: "Pause notifications" })).not.toBeInTheDocument();
    fireEvent(window, new Event("online"));
    expect(await screen.findByRole("combobox", { name: "Set status" })).toHaveValue("available");
  });

  it("rejects a delayed former-session response after authority changes", async () => {
    let resolveOld!: (value: Availability) => void;
    mocks.api.availability.mockReturnValueOnce(new Promise<Availability>((resolve) => { resolveOld = resolve; }));
    const { rerender } = render(view());
    mocks.session.access_token = "new-access";
    mocks.api.availability.mockResolvedValue({ ...available, status: "away", presence_state: "away" });
    rerender(view());
    await waitFor(() => expect(screen.getByRole("combobox", { name: "Set status" })).toHaveValue("away"));
    await act(async () => resolveOld({ ...available, status: "dnd", presence_state: "dnd", dnd_active: true }));
    expect(screen.getByRole("combobox", { name: "Set status" })).toHaveValue("away");
  });

  it("never submits an old user's change after their prerequisite read finishes", async () => {
    const user = userEvent.setup();
    const { rerender } = render(view());
    await screen.findByRole("combobox", { name: "Set status" });
    let resolveOld!: (value: Availability) => void;
    mocks.api.availability.mockReturnValueOnce(new Promise<Availability>((resolve) => { resolveOld = resolve; }));
    await user.click(screen.getByRole("button", { name: "Pause notifications" }));
    mocks.session.user.id = "user-2";
    rerender(view());
    await screen.findByRole("combobox", { name: "Set status" });
    await act(async () => resolveOld(available));
    expect(mocks.api.updateAvailability).not.toHaveBeenCalled();
  });
});


describe("availability response verification", () => {
  const invalidResponses: [string, unknown][] = [
    ["the unwrapped data array", []],
    ["null data", null],
    ["a missing weekly schedule", { ...available, dnd_schedule: undefined }],
    ["a null weekly schedule", { ...available, dnd_schedule: null }],
    ["an array instead of a schedule", { ...available, dnd_schedule: [] }],
    ["non-array schedule days", { ...available, dnd_schedule: { ...schedule, days: "weekdays" } }],
    ["duplicate schedule days", { ...available, dnd_schedule: { ...schedule, days: [1, 1] } }],
    ["a schedule outside the clock range", { ...available, dnd_schedule: { ...schedule, start: "24:00" } }],
    ["a partial weekly schedule", { ...available, dnd_schedule: { days: [1] } }],
    ["an unknown current status", { ...available, status: "ready" }],
    ["a non-boolean DND policy", { ...available, dnd_active: "false" }],
    ["an invalid expiry", { ...available, presence_expires_at: "later" }],
    ["an impossible calendar date", { ...available, presence_expires_at: "2026-02-30T12:00:00Z" }],
    ["an expiry at hour 24", { ...available, retry_at: "2026-10-07T24:00:00Z" }],
    ["a missing timezone", { ...available, timezone: undefined }]
  ];

  it.each(invalidResponses)("shows a recoverable error for %s without claiming a status", async (_name, response) => {
    // A successful HTTP { data: [] } is unwrapped to [] by the API domain.
    mocks.api.availability.mockResolvedValueOnce(response);
    render(view());
    expect(await screen.findByRole("alert")).toHaveTextContent("Availability could not be verified");
    expect(screen.queryByRole("combobox", { name: "Set status" })).not.toBeInTheDocument();
    expect(screen.queryByText("Ready to connect")).not.toBeInTheDocument();
    expect(mocks.api.updateAvailability).not.toHaveBeenCalled();
    mocks.api.availability.mockResolvedValue({ ...available, status: "dnd", presence_state: "dnd", dnd_active: true, dnd_schedule: schedule });
    await userEvent.setup().click(screen.getByRole("button", { name: "Retry availability" }));
    expect(await screen.findByRole("combobox", { name: "Set status" })).toHaveValue("dnd");
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(screen.getByText(/Your weekly schedule still applies/)).toBeVisible();
  });

  it("clears retained status when a background response cannot verify it", async () => {
    render(view());
    await screen.findByRole("combobox", { name: "Set status" });
    mocks.api.availability.mockResolvedValue([]);
    fireEvent.focus(window);
    expect(await screen.findByRole("alert")).toHaveTextContent("Availability could not be verified");
    expect(screen.queryByRole("combobox", { name: "Set status" })).not.toBeInTheDocument();
  });

  it("does not overwrite weekly policy after a malformed prerequisite read and supports a valid retry", async () => {
    const user = userEvent.setup();
    render(view());
    await screen.findByRole("combobox", { name: "Set status" });
    mocks.api.availability.mockResolvedValue({ ...available, dnd_schedule: { days: [1, 2] } });
    await user.click(screen.getByRole("button", { name: "Pause notifications" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Availability could not be verified");
    expect(mocks.api.updateAvailability).not.toHaveBeenCalled();
    expect(screen.queryByRole("combobox", { name: "Set status" })).not.toBeInTheDocument();
    mocks.api.availability.mockResolvedValue({ ...available, dnd_schedule: schedule });
    await user.click(screen.getByRole("button", { name: "Retry availability" }));
    await user.click(await screen.findByRole("button", { name: "Pause notifications" }));
    expect(await screen.findByText("Do not disturb saved.")).toBeVisible();
    expect(mocks.api.updateAvailability).toHaveBeenCalledExactlyOnceWith(expect.objectContaining({ dnd_schedule: schedule }));
  });

  it("does not claim success or retain unverifiable status after a malformed save acknowledgement", async () => {
    const user = userEvent.setup();
    mocks.api.updateAvailability.mockResolvedValue([]);
    render(view());
    await user.click(await screen.findByRole("button", { name: "Pause notifications" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Availability could not be verified");
    expect(screen.queryByRole("combobox", { name: "Set status" })).not.toBeInTheDocument();
    expect(screen.queryByText("Do not disturb saved.")).not.toBeInTheDocument();
    expect(window.localStorage.length).toBe(0);
    mocks.api.availability.mockResolvedValue({ ...available, status: "dnd", presence_state: "dnd", dnd_active: true });
    await user.click(screen.getByRole("button", { name: "Retry availability" }));
    expect(await screen.findByRole("combobox", { name: "Set status" })).toHaveValue("dnd");
  });

  it("ignores a malformed response from an obsolete session", async () => {
    let resolveOld!: (value: unknown) => void;
    mocks.api.availability.mockReturnValueOnce(new Promise((resolve) => { resolveOld = resolve; }));
    const { rerender } = render(view());
    mocks.session.access_token = "new-access";
    mocks.api.availability.mockResolvedValue({ ...available, status: "away", presence_state: "away" });
    rerender(view());
    await waitFor(() => expect(screen.getByRole("combobox", { name: "Set status" })).toHaveValue("away"));
    await act(async () => resolveOld([]));
    expect(screen.getByRole("combobox", { name: "Set status" })).toHaveValue("away");
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("uses explicitly labelled UTC when a server timezone is unsupported by browser ICU", async () => {
    const timezone = "America/Coyhaique";
    const until = new Date(Date.now() + 3_600_000).toISOString();
    const original = Intl.DateTimeFormat;
    const formatter = vi.spyOn(Intl, "DateTimeFormat").mockImplementation(function (locale, options) {
      if (options?.timeZone === timezone) throw new RangeError("Unsupported time zone");
      return new original(locale, options);
    });
    try {
      mocks.api.availability.mockResolvedValue({ ...available, timezone, status: "busy", presence_state: "busy", presence_expires_at: until });
      render(view());
      expect(await screen.findByRole("combobox", { name: "Set status" })).toHaveValue("busy");
      const time = screen.getByText(until);
      expect(time).toHaveAttribute("datetime", until);
      expect(time.parentElement).toHaveTextContent(`Until ${until} · UTC`);
      expect(screen.queryByText(timezone, { exact: false })).not.toBeInTheDocument();
      expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    } finally {
      formatter.mockRestore();
    }
  });
});
