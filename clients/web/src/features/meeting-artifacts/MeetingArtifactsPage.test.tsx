import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { MeetingArtifact } from "../../types/meeting-artifacts";
import { MeetingArtifactsPage } from "./MeetingArtifactsPage";

const api = vi.hoisted(() => ({ calls: vi.fn(), meetingArtifacts: vi.fn(), requestRecording: vi.fn(), artifactPlayback: vi.fn(), artifactTranscript: vi.fn() }));
const identity = vi.hoisted(() => ({ session: { access_token: "access-1", refresh_token: "refresh-1", tenant: { id: "tenant-1", status: "active" }, user: { id: "user-1", tenant_id: "tenant-1", role: "member", status: "active", version: 1 }, device: { id: "device-1", user_id: "user-1", revoked_at: null as string | null } } }));
vi.mock("../../app/session", () => ({ useSession: () => ({ api, session: identity.session }) }));
vi.mock("../../app/workspace-data", () => ({ useWorkspaceData: () => ({ conversations: [{ id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", title: "Product team", kind: "group" }], users: [{ id: "user-1", display_name: "Ada Lovelace" }] }) }));
const capabilities = { recording: false, recording_reason: "privacy_opt_in_required", participant_consent_required: true, persistent_transcript: false, persistent_transcript_reason: "qualified_provider_required", captions: "provider_events_only", automatic_capture: false } as const;

describe("MeetingArtifactsPage", () => {
  beforeEach(() => {
    identity.session = { access_token: "access-1", refresh_token: "refresh-1", tenant: { id: "tenant-1", status: "active" }, user: { id: "user-1", tenant_id: "tenant-1", role: "member", status: "active", version: 1 }, device: { id: "device-1", user_id: "user-1", revoked_at: null } };
    api.meetingArtifacts.mockReset().mockResolvedValue({ data: [], capabilities });
    api.calls.mockReset().mockResolvedValue({ data: [], page: { has_more: false, next_cursor: null } });
    api.requestRecording.mockReset();
    api.artifactPlayback.mockReset();
    api.artifactTranscript.mockReset();
  });

  it.each(["?conversation=not-a-room&call=not-a-call", "?conversation=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "?conversation=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa&call=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb&artifact=invalid"])("rejects incomplete or malformed retrieval links %s without fetching content", async query => {
    render(<MemoryRouter initialEntries={[`/app/artifacts${query}`]}><MeetingArtifactsPage /></MemoryRouter>);
    expect(screen.getByRole("alert")).toHaveTextContent("This recording link is incomplete.");
    expect(api.meetingArtifacts).not.toHaveBeenCalled();
    expect(api.requestRecording).not.toHaveBeenCalled();
    expect(api.calls).not.toHaveBeenCalled();
  });

  it("offers a recent-call library without fetching recording or transcript content", async () => {
    const conversation = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    const call = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    api.calls.mockResolvedValue({ data: [{ id: call, conversation_id: conversation, started_by_user_id: "user-1", started_at: "2026-10-04T12:00:00Z", media_kind: "video", status: "ended" }], page: { has_more: false, next_cursor: null } });
    render(<MemoryRouter initialEntries={["/app/artifacts"]}><MeetingArtifactsPage /></MemoryRouter>);
    const link = await screen.findByRole("link", { name: /View saved content for Product team/ });
    expect(link).toHaveAttribute("href", `/app/artifacts?conversation=${conversation}&call=${call}`);
    expect(screen.getByText("Started by Ada Lovelace")).toBeVisible();
    expect(api.calls).toHaveBeenCalledExactlyOnceWith({ scope: "recent", limit: 25, cursor: null });
    expect(api.meetingArtifacts).not.toHaveBeenCalled();
    expect(api.artifactPlayback).not.toHaveBeenCalled();
    expect(api.artifactTranscript).not.toHaveBeenCalled();
    const user = userEvent.setup();
    await user.type(screen.getByRole("searchbox", { name: "Find a conversation" }), "Different team");
    expect(screen.getByText("No matching loaded calls")).toBeVisible();
    expect(screen.getByText(/Search and filters apply to loaded calls/)).toBeVisible();
  });

  it("shows retryable library failure rather than a false empty result", async () => {
    api.calls.mockRejectedValueOnce(new Error("Current membership is required."));
    render(<MemoryRouter initialEntries={["/app/artifacts"]}><MeetingArtifactsPage /></MemoryRouter>);
    expect(await screen.findByRole("alert")).toHaveTextContent("Current membership is required.");
    expect(screen.queryByText("No recent calls")).not.toBeInTheDocument();
    await userEvent.setup().click(screen.getByRole("button", { name: "Try again" }));
    expect(await screen.findByText("No recent calls")).toBeVisible();
    expect(api.meetingArtifacts).not.toHaveBeenCalled();
  });

  it.each(["actor", "session"])("clears recent-call metadata and rejects a delayed former request after a same-api %s replacement", async replacement => {
    const call = { id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", conversation_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", started_at: "2026-10-04T12:00:00Z", media_kind: "video", status: "ended" };
    let resolveOlder: ((response: unknown) => void) | undefined;
    let resolveCurrent: ((response: unknown) => void) | undefined;
    api.calls.mockResolvedValueOnce({ data: [call], page: { has_more: true, next_cursor: "older" } });
    api.calls.mockImplementationOnce(() => new Promise(resolve => { resolveOlder = resolve; }));
    api.calls.mockImplementationOnce(() => new Promise(resolve => { resolveCurrent = resolve; }));
    const view = render(<MemoryRouter initialEntries={["/app/artifacts"]}><MeetingArtifactsPage /></MemoryRouter>);
    await userEvent.setup().click(await screen.findByRole("button", { name: "Load older calls" }));
    expect(screen.getByRole("link", { name: /View saved content for Product team/ })).toBeVisible();
    identity.session = replacement === "actor"
      ? { ...identity.session, tenant: { id: "tenant-2", status: "active" }, user: { ...identity.session.user, id: "user-2", tenant_id: "tenant-2" }, device: { ...identity.session.device, user_id: "user-2" } }
      : { ...identity.session, access_token: "access-2", refresh_token: "refresh-2" };
    view.rerender(<MemoryRouter initialEntries={["/app/artifacts"]}><MeetingArtifactsPage /></MemoryRouter>);
    expect(screen.queryByRole("link", { name: /View saved content for Product team/ })).not.toBeInTheDocument();
    await waitFor(() => expect(api.calls).toHaveBeenCalledTimes(3));
    await act(async () => { resolveCurrent?.({ data: [], page: { has_more: false, next_cursor: null } }); });
    expect(await screen.findByText("No recent calls")).toBeVisible();
    await act(async () => { resolveOlder?.({ data: [{ ...call, id: "stale-call" }], page: { has_more: false, next_cursor: null } }); });
    expect(screen.queryByRole("link", { name: /View saved content for Product team/ })).not.toBeInTheDocument();
    expect(screen.getByText("No recent calls")).toBeVisible();
    expect(api.meetingArtifacts).not.toHaveBeenCalled();
  });

  it("loads older calls once and clears displayed metadata when membership cannot be revalidated", async () => {
    const call = { id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", conversation_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", started_at: "2026-10-04T12:00:00Z", media_kind: "video", status: "ended" };
    api.calls.mockResolvedValueOnce({ data: [call], page: { has_more: true, next_cursor: "older" } });
    api.calls.mockResolvedValueOnce({ data: [call, { ...call, id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", started_at: "2026-10-03T12:00:00Z" }], page: { has_more: false, next_cursor: null } });
    render(<MemoryRouter initialEntries={["/app/artifacts"]}><MeetingArtifactsPage /></MemoryRouter>);
    await userEvent.setup().click(await screen.findByRole("button", { name: "Load older calls" }));
    const list = screen.getByRole("list", { name: "Recent calls for saved content" });
    await waitFor(() => expect(within(list).getAllByRole("listitem")).toHaveLength(2));
    expect(api.calls).toHaveBeenLastCalledWith({ scope: "recent", limit: 25, cursor: "older" });
    api.calls.mockRejectedValueOnce(new Error("Membership revoked."));
    fireEvent(window, new Event("focus"));
    expect(await screen.findByRole("alert")).toHaveTextContent("Membership revoked.");
    expect(within(list).queryAllByRole("listitem")).toHaveLength(0);
    expect(api.meetingArtifacts).not.toHaveBeenCalled();
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
    expect(row).toHaveTextContent("Post-recording transcript");
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
