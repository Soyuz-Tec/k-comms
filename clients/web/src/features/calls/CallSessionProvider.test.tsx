import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, useLocation, useNavigate } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { CallMediaKind, Conversation } from "../../types";
import {
  CallSessionProvider,
  useCallSession
} from "./CallSessionProvider";

const firstConversation: Conversation = {
  id: "conversation-1",
  tenant_id: "tenant-1",
  kind: "group",
  title: "Execution room",
  counterpart_user_id: null,
  counterpart_display_name: null,
  visibility: "private",
  latest_sequence: 0,
  inserted_at: "2026-07-24T00:00:00Z",
  updated_at: "2026-07-24T00:00:00Z"
};

const secondConversation: Conversation = {
  ...firstConversation,
  id: "conversation-2",
  title: "Finance room"
};

const harness = vi.hoisted(() => ({
  mounts: 0,
  unmounts: 0,
  allowAudio: true,
  allowVideo: true,
  audioAvailable: true,
  videoAvailable: true,
  workspaceLoading: false
}));

vi.mock("./CallPanel", async () => {
  const { useEffect } = await import("react");
  return {
    CallPanel: ({
      audioEnabled,
      conversation,
      launchRequest,
      launchRequestId,
      onLaunchRequestConsumed,
      onSessionStateChange,
      videoEnabled
    }: {
      audioEnabled: boolean;
      conversation: Conversation;
      launchRequest?: CallMediaKind | null;
      launchRequestId?: number;
      onLaunchRequestConsumed?: () => void;
      onSessionStateChange?: (state: {
        conversationId: string;
        callId: string | null;
        phase: "prejoin" | "connected";
        mediaKind: CallMediaKind;
        joined: boolean;
        microphoneEnabled: boolean;
        cameraEnabled: boolean;
        screenShareEnabled: boolean;
        canEnd: boolean;
        accessRevoked: boolean;
      }) => void;
      videoEnabled: boolean;
    }) => {
      useEffect(() => {
        harness.mounts += 1;
        return () => {
          harness.unmounts += 1;
        };
      }, []);
      useEffect(() => {
        if (!launchRequest || !launchRequestId) return;
        onLaunchRequestConsumed?.();
        onSessionStateChange?.({
          conversationId: conversation.id,
          callId: null,
          phase: "prejoin",
          mediaKind: launchRequest,
          joined: false,
          microphoneEnabled: false,
          cameraEnabled: false,
          screenShareEnabled: false,
          canEnd: false,
          accessRevoked: false
        });
      }, [
        conversation.id,
        launchRequest,
        launchRequestId,
        onLaunchRequestConsumed,
        onSessionStateChange
      ]);
      return (
        <output
          aria-label="persistent call owner"
          data-audio-enabled={audioEnabled}
          data-video-enabled={videoEnabled}
        >
          {conversation.id}
        </output>
      );
    }
  };
});

vi.mock("../../app/session", () => ({
  useSession: () => ({
    api: {},
    session: {
      user: { id: "user-1", display_name: "Ada" }
    }
  })
}));

vi.mock("../../app/workspace-data", () => ({
  useWorkspaceData: () => ({
    audioCallsAvailable: harness.audioAvailable,
    videoCallsAvailable: harness.videoAvailable,
    loading: harness.workspaceLoading,
    capabilities: {
      allow_audio_calls: harness.allowAudio,
      allow_video_calls: harness.allowVideo
    }
  })
}));

function Harness() {
  const {
    launchCall,
    targetConversation
  } = useCallSession();
  const location = useLocation();
  const navigate = useNavigate();
  return (
    <main>
      <output aria-label="route">{location.pathname}</output>
      <output aria-label="target">{targetConversation?.id || "none"}</output>
      <button type="button" onClick={() => launchCall(firstConversation, "audio")}>
        Call execution
      </button>
      <button type="button" onClick={() => launchCall(secondConversation, "video")}>
        Call finance
      </button>
      <button
        type="button"
        onClick={() => {
          launchCall(firstConversation, "audio");
          launchCall(firstConversation, "video");
        }}
      >
        Rapid launch
      </button>
      <button type="button" onClick={() => navigate("/app/files")}>Open files</button>
    </main>
  );
}

function renderProvider() {
  return render(
    <MemoryRouter initialEntries={["/app"]}>
      <CallSessionProvider>
        <Harness />
      </CallSessionProvider>
    </MemoryRouter>
  );
}

describe("CallSessionProvider", () => {
  beforeEach(() => {
    harness.mounts = 0;
    harness.unmounts = 0;
    harness.allowAudio = true;
    harness.allowVideo = true;
    harness.audioAvailable = true;
    harness.videoAvailable = true;
    harness.workspaceLoading = false;
  });

  it("keeps one call owner mounted while feature routes change and blocks another target", async () => {
    const user = userEvent.setup();
    renderProvider();

    await user.click(screen.getByRole("button", { name: "Call execution" }));
    expect(await screen.findByLabelText("persistent call owner")).toHaveTextContent(
      firstConversation.id
    );
    await waitFor(() => expect(harness.mounts).toBe(1));

    await user.click(screen.getByRole("button", { name: "Open files" }));
    expect(screen.getByLabelText("route")).toHaveTextContent("/app/files");
    expect(screen.getByLabelText("persistent call owner")).toHaveTextContent(
      firstConversation.id
    );
    expect(harness.mounts).toBe(1);
    expect(harness.unmounts).toBe(0);

    await user.click(screen.getByRole("button", { name: "Call finance" }));
    // Still blocked from replacing the foreground call -- but the second
    // target now opens the switch flow rather than a dead-end notice, so the
    // assertion is that the owner has not moved, and that a confirmation is
    // being asked for rather than anything being done.
    expect(screen.getByLabelText("target")).toHaveTextContent(firstConversation.id);
    expect(await screen.findByRole("alertdialog")).toHaveTextContent(/Switch to the call in/);
    await user.click(screen.getByRole("button", { name: "Cancel" }));
    expect(screen.getByLabelText("target")).toHaveTextContent(firstConversation.id);
  });

  it("does not let a rapid second launch overwrite a pending media kind", async () => {
    const user = userEvent.setup();
    renderProvider();

    await user.click(screen.getByRole("button", { name: "Rapid launch" }));
    expect(await screen.findByLabelText("persistent call owner")).toHaveTextContent(
      firstConversation.id
    );
    expect(screen.getByText(
      "Finish or cancel the current audio call lobby first."
    )).toBeVisible();
  });

  it("blocks direct launches when workspace policy disables the media kind", async () => {
    harness.allowAudio = false;
    const user = userEvent.setup();
    renderProvider();

    await user.click(screen.getByRole("button", { name: "Call execution" }));

    expect(screen.getByLabelText("target")).toHaveTextContent("none");
    expect(screen.queryByLabelText("persistent call owner")).not.toBeInTheDocument();
    expect(screen.getByText(/Audio calling is disabled by workspace policy/)).toBeVisible();
  });

  it("blocks direct launches while the provider is unavailable", async () => {
    harness.audioAvailable = false;
    const user = userEvent.setup();
    renderProvider();

    await user.click(screen.getByRole("button", { name: "Call execution" }));

    expect(screen.getByLabelText("target")).toHaveTextContent("none");
    expect(screen.queryByLabelText("persistent call owner")).not.toBeInTheDocument();
    expect(screen.getByText(/Audio calling is temporarily unavailable/)).toBeVisible();
  });

  it("blocks direct launches while availability is still loading", async () => {
    harness.workspaceLoading = true;
    const user = userEvent.setup();
    renderProvider();

    await user.click(screen.getByRole("button", { name: "Call execution" }));

    expect(screen.getByLabelText("target")).toHaveTextContent("none");
    expect(screen.getByText(/Call availability is still being checked/)).toBeVisible();
  });

  it("does not turn a transient provider-readiness loss into active-call policy revocation", async () => {
    const user = userEvent.setup();
    const view = renderProvider();
    await user.click(screen.getByRole("button", { name: "Call execution" }));
    expect(await screen.findByLabelText("persistent call owner"))
      .toHaveAttribute("data-audio-enabled", "true");

    harness.audioAvailable = false;
    view.rerender(
      <MemoryRouter initialEntries={["/app"]}>
        <CallSessionProvider>
          <Harness />
        </CallSessionProvider>
      </MemoryRouter>
    );

    expect(screen.getByLabelText("persistent call owner"))
      .toHaveAttribute("data-audio-enabled", "true");

    harness.allowAudio = false;
    view.rerender(
      <MemoryRouter initialEntries={["/app"]}>
        <CallSessionProvider>
          <Harness />
        </CallSessionProvider>
      </MemoryRouter>
    );
    expect(screen.getByLabelText("persistent call owner"))
      .toHaveAttribute("data-audio-enabled", "false");
  });
});
