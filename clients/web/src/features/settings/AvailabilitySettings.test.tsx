import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { AvailabilitySettings } from "./AvailabilitySettings";

const mocks = vi.hoisted(() => ({ api: { availability: vi.fn(), updateAvailability: vi.fn() } }));
vi.mock("../../app/session", () => ({ useSession: () => ({ api: mocks.api }) }));
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
    expect(await screen.findByRole("status")).toHaveTextContent("incoming ringing");
  });
  it("retains editable state on a failed policy save", async () => {
    const user = userEvent.setup(); mocks.api.updateAvailability.mockRejectedValue(new Error("Policy unavailable"));
    render(<AvailabilitySettings />); await screen.findByRole("button", { name: "Save availability" });
    await user.selectOptions(screen.getByLabelText("Availability"), "busy");
    await user.click(screen.getByRole("button", { name: "Save availability" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Policy unavailable");
    expect(screen.getByLabelText("Availability")).toHaveValue("busy");
  });
});
