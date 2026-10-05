import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { MeetingArtifact } from "../../types/meeting-artifacts";
import { MeetingArtifactsPage } from "./MeetingArtifactsPage";

const api = vi.hoisted(() => ({ meetingArtifacts: vi.fn(), requestRecording: vi.fn(), artifactPlayback: vi.fn(), artifactTranscript: vi.fn() }));
vi.mock("../../app/session", () => ({ useSession: () => ({ api }) }));
const capabilities = { recording: false, recording_reason: "privacy_opt_in_required", participant_consent_required: true, persistent_transcript: false, persistent_transcript_reason: "qualified_provider_required", captions: "provider_events_only", automatic_capture: false } as const;

describe("MeetingArtifactsPage", () => {
  beforeEach(() => {
    api.meetingArtifacts.mockReset().mockResolvedValue({ data: [], capabilities });
    api.requestRecording.mockReset();
    api.artifactPlayback.mockReset();
    api.artifactTranscript.mockReset();
  });

  it.each(["", "?conversation=not-a-room&call=not-a-call", "?conversation=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "?conversation=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa&call=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb&artifact=invalid"])("rejects incomplete or malformed retrieval links %s without fetching content", async query => {
    render(<MemoryRouter initialEntries={[`/app/artifacts${query}`]}><MeetingArtifactsPage /></MemoryRouter>);
    expect(screen.getByRole("alert")).toHaveTextContent("This recording link is incomplete.");
    expect(api.meetingArtifacts).not.toHaveBeenCalled();
    expect(api.requestRecording).not.toHaveBeenCalled();
  });

  it("focuses the exact authorized saved artifact without playing media or retrieving transcript content", async () => {
    const conversation = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    const call = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    const artifact = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
    const selected: MeetingArtifact = { id: artifact, conversation_id: conversation, call_id: call, kind: "transcript", status: "available", created_at: "2026-10-04T12:00:00Z", expires_at: "2099-01-01T00:00:00Z", consent_required_count: 2, consent_accepted_count: 2, my_consent: true, can_manage: false, content_type: "application/json" };
    api.meetingArtifacts.mockResolvedValue({ capabilities, data: [{ ...selected, id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", kind: "recording", content_type: "video/mp4" }, selected] });
    const view = render(<MemoryRouter initialEntries={[`/app/artifacts?conversation=${conversation}&call=${call}&artifact=${artifact}`]}><MeetingArtifactsPage /></MemoryRouter>);
    const row = await waitFor(() => {
      const element = view.container.querySelector("li[data-selected='true']");
      expect(element).not.toBeNull();
      return element as HTMLElement;
    });
    expect(row).toHaveTextContent("Transcript");
    await waitFor(() => expect(row).toHaveFocus());
    expect(api.artifactPlayback).not.toHaveBeenCalled();
    expect(api.artifactTranscript).not.toHaveBeenCalled();
    expect(api.requestRecording).not.toHaveBeenCalled();
  });

  it("reports an unavailable exact artifact without choosing a different recording", async () => {
    render(<MemoryRouter initialEntries={["/app/artifacts?conversation=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa&call=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb&artifact=cccccccc-cccc-4ccc-8ccc-cccccccccccc"]}><MeetingArtifactsPage /></MemoryRouter>);
    expect(await screen.findByRole("alert")).toHaveTextContent("The linked recording or transcript is unavailable.");
    expect(api.artifactPlayback).not.toHaveBeenCalled();
    expect(api.artifactTranscript).not.toHaveBeenCalled();
  });

  it("retrieves a referenced call under current authorization without requesting capture", async () => {
    const conversation = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    const call = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    render(<MemoryRouter initialEntries={[`/app/artifacts?conversation=${conversation}&call=${call}`]}><MeetingArtifactsPage /></MemoryRouter>);
    await waitFor(() => expect(api.meetingArtifacts).toHaveBeenCalledExactlyOnceWith(conversation, call));
    expect(screen.getByRole("link", { name: "Open conversation" })).toHaveAttribute("href", `/app/?conversation=${conversation}`);
    expect(await screen.findByText("No saved artifacts for this call.")).toBeVisible();
    expect(screen.queryByRole("button", { name: "Request recording consent" })).not.toBeInTheDocument();
    expect(api.requestRecording).not.toHaveBeenCalled();
  });
});
