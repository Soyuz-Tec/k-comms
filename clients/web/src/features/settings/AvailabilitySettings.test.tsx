import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { AvailabilitySettings } from "./AvailabilitySettings";
import { ApiError } from "../../api/errors";

const mocks = vi.hoisted(() => ({ api: { availability: vi.fn(), updateAvailability: vi.fn() }, session: { tenant: { id: "tenant-1" }, user: { id: "user-1" }, device: { id: "device-1" }, access_token: "access" } }));
vi.mock("../../app/session", () => ({ useSession: () => ({ api: mocks.api, session: mocks.session }) }));
const state = { status: "available", presence_state: "available", presence_expires_at: null, dnd_until: null, dnd_schedule: {}, dnd_active: false, retry_at: null, timezone: "America/New_York" };
beforeEach(() => { mocks.api.availability.mockReset(); mocks.api.updateAvailability.mockReset(); mocks.api.availability.mockResolvedValue(state); });
describe("persistent availability settings", () => {
  it("saves weekly DND as an actual backend policy in the profile timezone", async () => {
    const user = userEvent.setup(); mocks.api.updateAvailability.mockResolvedValue({ ...state, status: "dnd", dnd_active: true });
    render(<AvailabilitySettings />);
    await screen.findByText(/Schedules use America\/New_York/);
    await user.selectOptions(screen.getByLabelText("Availability"), "dnd");
    await user.click(screen.getByLabelText("Enable weekly do not disturb schedule"));
    await user.click(screen.getByLabelText("Mon"));
    await user.click(screen.getByRole("button", { name: "Save availability" }));
    expect(mocks.api.updateAvailability).toHaveBeenCalledWith({ presence_state: "dnd", presence_expires_at: null, dnd_until: null, dnd_schedule: { days: [1], start: "22:00", end: "08:00" } });
    expect(await screen.findByRole("status")).toHaveTextContent("pauses email and push");
  });
  it("retains editable state on a failed policy save", async () => {
    const user = userEvent.setup(); mocks.api.updateAvailability.mockRejectedValue(new Error("Policy unavailable"));
    render(<AvailabilitySettings />); await screen.findByRole("button", { name: "Save availability" });
    await user.selectOptions(screen.getByLabelText("Availability"), "busy");
    await user.click(screen.getByRole("button", { name: "Save availability" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Policy unavailable");
    expect(screen.getByLabelText("Availability")).toHaveValue("busy");
  });
  it("updates the current status without replacing unsaved policy edits on focus", async () => {
    const user = userEvent.setup();
    render(<AvailabilitySettings />);
    await user.selectOptions(await screen.findByLabelText("Availability"), "busy");
    mocks.api.availability.mockResolvedValue({ ...state, status: "away", presence_state: "away" });
    fireEvent.focus(window);
    await waitFor(() => expect(screen.getByText(/Current availability:/)).toHaveTextContent("away"));
    expect(screen.getByLabelText("Availability")).toHaveValue("busy");
    expect(screen.queryByLabelText("Start")).not.toBeInTheDocument();
  });
  it("preserves a quick status deadline when saving schedule preferences", async () => {
    const value = { ...state, status: "busy", presence_state: "busy", presence_expires_at: new Date(Date.now() + 60_000).toISOString() };
    mocks.api.availability.mockResolvedValue(value);
    mocks.api.updateAvailability.mockResolvedValue(value);
    render(<AvailabilitySettings />);
    expect(await screen.findByLabelText("Duration")).toHaveValue("keep");
    await userEvent.setup().click(screen.getByRole("button", { name: "Save availability" }));
    expect(mocks.api.updateAvailability).toHaveBeenCalledWith({ presence_state: "busy", presence_expires_at: value.presence_expires_at, dnd_until: null, dnd_schedule: {} });
  });
  it("restores unfinished settings after a transient refresh failure", async () => {
    const user = userEvent.setup();
    render(<AvailabilitySettings />);
    await user.selectOptions(await screen.findByLabelText("Availability"), "busy");
    await user.selectOptions(screen.getByLabelText("Duration"), "30");
    await user.click(screen.getByLabelText("Enable weekly do not disturb schedule"));
    await user.click(screen.getByLabelText("Mon"));
    fireEvent.change(screen.getByLabelText("Start"), { target: { value: "09:00" } });
    mocks.api.availability.mockRejectedValueOnce(new Error("Temporarily unavailable"));
    fireEvent.focus(window);
    await screen.findByRole("alert");
    expect(screen.queryByLabelText("Availability")).not.toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Retry availability" }));
    expect(await screen.findByLabelText("Availability")).toHaveValue("busy");
    expect(screen.getByLabelText("Duration")).toHaveValue("30");
    expect(screen.getByLabelText("Mon")).toBeChecked();
    expect(screen.getByLabelText("Start")).toHaveValue("09:00");
  });
  it("clears unfinished settings after an explicit authorization failure", async () => {
    const user = userEvent.setup();
    render(<AvailabilitySettings />);
    await user.selectOptions(await screen.findByLabelText("Availability"), "busy");
    mocks.api.availability.mockRejectedValueOnce(new ApiError(403, "forbidden", "Access changed"));
    fireEvent.focus(window);
    await screen.findByRole("alert");
    await user.click(screen.getByRole("button", { name: "Retry availability" }));
    expect(await screen.findByLabelText("Availability")).toHaveValue("available");
  });
});
