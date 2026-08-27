import { render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

const callSession = { sessionState: null as { conversationId: string; phase: string } | null };
const workspace = {
  capabilities: { allow_immersive_mode: true } as Record<string, unknown> | null,
  serviceStatus: { capabilities: { immersive_mode: true } } as Record<string, unknown> | null,
  loading: false
};

vi.mock("../calls/CallSessionProvider", () => ({
  useCallSession: () => callSession
}));
vi.mock("../../app/workspace-data", () => ({
  useWorkspaceData: () => workspace
}));

const { ExperienceModeProvider, useExperienceMode } = await import("./ExperienceModeProvider");

function Probe() {
  const { mode, immersiveEligible } = useExperienceMode();
  return <span data-testid="mode">{`${mode}:${immersiveEligible}`}</span>;
}

function renderProvider() {
  return render(
    <ExperienceModeProvider>
      <Probe />
    </ExperienceModeProvider>
  );
}

async function expectMode(value: string) {
  await waitFor(() => expect(screen.getByTestId("mode").textContent).toBe(value));
}

describe("ExperienceModeProvider", () => {
  beforeEach(() => {
    callSession.sessionState = null;
    workspace.capabilities = { allow_immersive_mode: true };
    workspace.serviceStatus = { capabilities: { immersive_mode: true } };
    workspace.loading = false;
  });

  it("stays in workspace with no call", async () => {
    renderProvider();
    await expectMode("workspace:true");
  });

  it("enters immersive when media connection begins for an eligible client", async () => {
    callSession.sessionState = { conversationId: "conv-1", phase: "joining" };
    renderProvider();
    await expectMode("immersive:true");
  });

  it("stays in workspace when the deployment switch is off", async () => {
    workspace.serviceStatus = { capabilities: { immersive_mode: false } };
    callSession.sessionState = { conversationId: "conv-1", phase: "joining" };
    renderProvider();
    await expectMode("workspace:false");
  });

  it("stays in workspace when the tenant switch is off", async () => {
    workspace.capabilities = { allow_immersive_mode: false };
    callSession.sessionState = { conversationId: "conv-1", phase: "joining" };
    renderProvider();
    await expectMode("workspace:false");
  });

  it("returns to workspace when the call ends", async () => {
    callSession.sessionState = { conversationId: "conv-1", phase: "joining" };
    const view = renderProvider();
    await expectMode("immersive:true");

    callSession.sessionState = null;
    view.rerender(
      <ExperienceModeProvider>
        <Probe />
      </ExperienceModeProvider>
    );
    await expectMode("workspace:true");
  });

  it("does not decide again as the same call moves past joining", async () => {
    // The decision is taken at media-connect and must survive the phases that
    // follow it; re-deciding on 'connected' would remount the media tree.
    workspace.serviceStatus = { capabilities: { immersive_mode: false } };
    callSession.sessionState = { conversationId: "conv-1", phase: "joining" };
    const view = renderProvider();
    await expectMode("workspace:false");

    workspace.serviceStatus = { capabilities: { immersive_mode: true } };
    callSession.sessionState = { conversationId: "conv-1", phase: "connected" };
    view.rerender(
      <ExperienceModeProvider>
        <Probe />
      </ExperienceModeProvider>
    );
    await expectMode("workspace:true");
  });

  it("fails closed while capabilities are still loading at the deadline", async () => {
    vi.useFakeTimers();
    try {
      workspace.loading = true;
      workspace.capabilities = null;
      workspace.serviceStatus = null;
      callSession.sessionState = { conversationId: "conv-1", phase: "joining" };
      renderProvider();
      await vi.advanceTimersByTimeAsync(400);
      expect(screen.getByTestId("mode").textContent).toBe("workspace:false");
    } finally {
      vi.useRealTimers();
    }
  });
});
