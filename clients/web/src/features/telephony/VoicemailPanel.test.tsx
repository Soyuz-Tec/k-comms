import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { VoicemailPanel } from "./VoicemailPanel";
const harness = vi.hoisted(() => ({ api: { voicemails: vi.fn(), voicemailPlayback: vi.fn(), markVoicemailRead: vi.fn(), deleteVoicemail: vi.fn() } }));
vi.mock("../../app/session", () => ({ useSession: () => ({ api: harness.api }) }));
const message = { id: "voice", call_id: "call", status: "available", duration_seconds: 3, inserted_at: "2026-10-05T12:00:00Z", retention_expires_at: "2026-11-05T12:00:00Z", available_at: "2026-10-05T12:00:00Z", read_at: null };
describe("voicemail panel", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    harness.api.voicemails.mockResolvedValue({ data: [message], configured: true, page: { limit: 30, has_more: false, next_cursor: null } });
    harness.api.voicemailPlayback.mockResolvedValue({ url: "https://storage.example.test/voice.wav?versionId=exact", approved_origin: "https://storage.example.test", development_http: false, expires_in: 120, expires_at: new Date(Date.now() + 120_000).toISOString(), content_type: "audio/wav" });
    harness.api.markVoicemailRead.mockResolvedValue({ ...message, read_at: "2026-10-05T13:00:00Z" });
    harness.api.deleteVoicemail.mockResolvedValue({ status: "deleting" });
  });
  it("marks read only after playback begins and asks for a concrete deletion confirmation", async () => {
    render(<VoicemailPanel />);
    await userEvent.setup().click(await screen.findByRole("button", { name: "Listen to voicemail" }));
    const audio = screen.getByLabelText("Voicemail playback");
    expect(audio).toHaveAttribute("src", "https://storage.example.test/voice.wav?versionId=exact");
    expect(harness.api.markVoicemailRead).not.toHaveBeenCalled();
    fireEvent.play(audio);
    await waitFor(() => expect(harness.api.markVoicemailRead).toHaveBeenCalledWith("voice"));
    await userEvent.setup().click(screen.getByRole("button", { name: "Delete voicemail" }));
    expect(harness.api.deleteVoicemail).not.toHaveBeenCalled();
    await userEvent.setup().click(screen.getByRole("button", { name: "Confirm deletion" }));
    expect(await screen.findByText("Deletion in progress")).toBeVisible();
    expect(screen.queryByLabelText("Voicemail playback")).not.toBeInTheDocument();
  });
  it("rejects playback from a foreign origin and preserves a held message after deletion is denied", async () => {
    harness.api.voicemailPlayback.mockResolvedValueOnce({ url: "https://foreign.example.test/voice.wav?versionId=exact", approved_origin: "https://storage.example.test", development_http: false, content_type: "audio/wav", expires_at: new Date(Date.now() + 120_000).toISOString() });
    harness.api.deleteVoicemail.mockRejectedValueOnce(new Error("This recording is protected by a legal hold"));
    render(<VoicemailPanel />);
    await userEvent.setup().click(await screen.findByRole("button", { name: "Listen to voicemail" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Playback could not be verified");
    expect(screen.queryByLabelText("Voicemail playback")).not.toBeInTheDocument();
    await userEvent.setup().click(screen.getByRole("button", { name: "Delete voicemail" }));
    await userEvent.setup().click(screen.getByRole("button", { name: "Confirm deletion" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("legal hold");
    expect(screen.getByRole("button", { name: "Listen to voicemail" })).toBeEnabled();
  });
  it("explains disabled capture and retains message history", async () => {
    harness.api.voicemails.mockResolvedValue({ data: [message], configured: false, page: { limit: 30, has_more: false, next_cursor: null } });
    render(<VoicemailPanel />);
    expect(await screen.findByText(/Voicemail capture needs a verified phone provider/)).toBeVisible();
    expect(screen.getByRole("button", { name: "Listen to voicemail" })).toBeVisible();
  });
  it("shows caller identity but offers callback only for an unambiguous international number", async () => {
    harness.api.voicemails.mockResolvedValueOnce({ data: [{ ...message, caller_number: "+14155550123" }, { ...message, id: "withheld", caller_number: "Unknown" }], configured: true, page: { limit: 30, has_more: false, next_cursor: null } });
    const useNumber = vi.fn();
    render(<VoicemailPanel onUseNumber={useNumber} />);
    expect(await screen.findByText("+14155550123")).toBeVisible();
    expect(screen.getAllByRole("button", { name: "Return call" })).toHaveLength(1);
    await userEvent.setup().click(screen.getByRole("button", { name: "Return call" }));
    expect(useNumber).toHaveBeenCalledExactlyOnceWith("+14155550123");
    expect(harness.api.voicemailPlayback).not.toHaveBeenCalled();
  });
  it("clears caller data and signed audio when playback authority is withdrawn", async () => {
    harness.api.voicemails.mockResolvedValueOnce({ data: [{ ...message, caller_number: "+14155550123" }], configured: true, page: { limit: 30, has_more: false, next_cursor: null } });
    harness.api.markVoicemailRead.mockRejectedValueOnce(Object.assign(new Error("Voicemail access withdrawn"), { status: 403 }));
    render(<VoicemailPanel onUseNumber={vi.fn()} />);
    await userEvent.setup().click(await screen.findByRole("button", { name: "Listen to voicemail" }));
    fireEvent.play(screen.getByLabelText("Voicemail playback"));
    expect(await screen.findByRole("alert")).toHaveTextContent("Voicemail access withdrawn");
    expect(screen.queryByText("+14155550123")).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Voicemail playback")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Return call" })).not.toBeInTheDocument();
  });
});
