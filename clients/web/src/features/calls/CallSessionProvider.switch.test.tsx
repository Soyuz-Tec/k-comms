import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MemoryRouter } from "react-router";
import type { CallPanelSessionState } from "./callContracts";
import type { Conversation } from "../../types";
import { CALL_SWITCH_LEAVE_TIMEOUT_MS } from "./call-switch";

/*
 * The persistent panel is replaced with a stub that reports whatever session
 * state the test dictates. The flow under test is the provider's sequencing --
 * confirm, leave, observe the release, then join -- not LiveKit.
 */
const panel = vi.hoisted(() => ({
  onSessionStateChange: null as ((state: CallPanelSessionState) => void) | null,
  conversationIds: [] as string[]
}));

vi.mock("./CallPanel", () => ({
  CallPanel: (props: {
    conversation: Conversation;
    onSessionStateChange?: (state: CallPanelSessionState) => void;
  }) => {
    panel.onSessionStateChange = props.onSessionStateChange ?? null;
    if (!panel.conversationIds.includes(props.conversation.id)) {
      panel.conversationIds.push(props.conversation.id);
    }
    return <div data-testid="call-panel" data-conversation={props.conversation.id} />;
  }
}));

const workspace = vi.hoisted(() => ({
  audioCallsAvailable: true,
  videoCallsAvailable: true,
  loading: false,
  capabilities: { allow_audio_calls: true, allow_video_calls: true } as Record<string, unknown>
}));

vi.mock("../../app/workspace-data", () => ({
  useWorkspaceData: () => workspace
}));
vi.mock("../../app/session", () => ({
  useSession: () => ({ api: {}, session: { user: { id: "user-1" } } })
}));

const { CallSessionProvider, useCallSession } = await import("./CallSessionProvider");

const standup: Conversation = {
  id: "conversation-1",
  tenant_id: "tenant-1",
  kind: "channel",
  title: "Standup",
  visibility: "private",
  inserted_at: "2026-08-01T00:00:00Z",
  updated_at: "2026-08-01T00:00:00Z",
  counterpart_user_id: null,
  counterpart_display_name: null,
  latest_sequence: 0
};

const design: Conversation = { ...standup, id: "conversation-2", title: "Design" };

function sessionAt(conversationId: string, phase: CallPanelSessionState["phase"]): CallPanelSessionState {
  return {
    conversationId,
    callId: "call-1",
    phase,
    mediaKind: "audio",
    joined: phase === "connected",
    microphoneEnabled: true,
    cameraEnabled: false,
    screenShareEnabled: false,
    canEnd: false,
    accessRevoked: false,
    transportMode: "livekit"
  };
}

function Harness() {
  const { launchCall } = useCallSession();
  return (
    <>
      <button type="button" onClick={() => launchCall(standup, "audio")}>Call Standup</button>
      <button type="button" onClick={() => launchCall(design, "audio")}>Call Design</button>
    </>
  );
}

function renderProvider() {
  return render(
    <MemoryRouter>
      <CallSessionProvider>
        <Harness />
      </CallSessionProvider>
    </MemoryRouter>
  );
}

function report(state: CallPanelSessionState) {
  act(() => panel.onSessionStateChange?.(state));
}

async function joinStandup(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByRole("button", { name: "Call Standup" }));
  await waitFor(() => expect(screen.getByTestId("call-panel")).toBeInTheDocument());
  report(sessionAt(standup.id, "connected"));
}

describe("switching between calls", () => {
  beforeEach(() => {
    panel.onSessionStateChange = null;
    panel.conversationIds = [];
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("asks before touching the call already running", async () => {
    const user = userEvent.setup();
    renderProvider();
    await joinStandup(user);

    await user.click(screen.getByRole("button", { name: "Call Design" }));

    expect(await screen.findByRole("alertdialog")).toHaveTextContent(
      "Switch to the call in Design?"
    );
    // Nothing has happened yet: the panel is still the first conversation's.
    expect(screen.getByTestId("call-panel")).toHaveAttribute("data-conversation", standup.id);
  });

  it("leaves the current call alone when the switch is declined", async () => {
    const user = userEvent.setup();
    renderProvider();
    await joinStandup(user);
    await user.click(screen.getByRole("button", { name: "Call Design" }));

    await user.click(screen.getByRole("button", { name: "Cancel" }));
    await waitFor(() => expect(screen.queryByRole("alertdialog")).toBeNull());
    expect(screen.getByTestId("call-panel")).toHaveAttribute("data-conversation", standup.id);
    expect(panel.conversationIds).toEqual([standup.id]);
  });

  it("does not join the next call while the leave is still pending", async () => {
    // The rule the whole flow exists for: two rooms must never be connected,
    // so nothing joins until the first one has actually released.
    const user = userEvent.setup();
    renderProvider();
    await joinStandup(user);
    await user.click(screen.getByRole("button", { name: "Call Design" }));
    await user.click(screen.getByRole("button", { name: "Leave and switch" }));

    report(sessionAt(standup.id, "leaving"));

    expect(await screen.findByText(/Leaving Standup before joining Design/)).toBeVisible();
    expect(screen.getByTestId("call-panel")).toHaveAttribute("data-conversation", standup.id);
    expect(panel.conversationIds).toEqual([standup.id]);
  });

  it("joins the next call once the previous one has released", async () => {
    const user = userEvent.setup();
    renderProvider();
    await joinStandup(user);
    await user.click(screen.getByRole("button", { name: "Call Design" }));
    await user.click(screen.getByRole("button", { name: "Leave and switch" }));

    report(sessionAt(standup.id, "leaving"));
    report(sessionAt(standup.id, "ended"));

    await waitFor(() =>
      expect(screen.getByTestId("call-panel")).toHaveAttribute("data-conversation", design.id)
    );
    expect(screen.queryByText(/Leaving Standup/)).toBeNull();
  });

  it("says the switch failed and keeps the original call when the leave stalls", async () => {
    // Never claim success while the leave is pending or failed. A stalled
    // leave is reported as what it is, with the first call retained.
    vi.useFakeTimers({ shouldAdvanceTime: true });
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    renderProvider();
    await joinStandup(user);
    await user.click(screen.getByRole("button", { name: "Call Design" }));
    await user.click(screen.getByRole("button", { name: "Leave and switch" }));
    report(sessionAt(standup.id, "leaving"));

    await act(async () => {
      await vi.advanceTimersByTimeAsync(CALL_SWITCH_LEAVE_TIMEOUT_MS + 100);
    });

    const alert = await screen.findByRole("alert");
    expect(alert).toHaveTextContent("Could not leave Standup");
    expect(alert).toHaveTextContent("still in Standup");
    expect(screen.getByTestId("call-panel")).toHaveAttribute("data-conversation", standup.id);
    expect(panel.conversationIds).toEqual([standup.id]);
  });

  it("still launches directly when no call is running", async () => {
    const user = userEvent.setup();
    renderProvider();
    await user.click(screen.getByRole("button", { name: "Call Design" }));

    await waitFor(() =>
      expect(screen.getByTestId("call-panel")).toHaveAttribute("data-conversation", design.id)
    );
    expect(screen.queryByRole("alertdialog")).toBeNull();
  });
});
