import { render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it } from "vitest";
import { useExperienceModeController } from "./ExperienceModeProvider";
import type { ServiceStatus, UserCapabilities } from "../../types";

/*
 * Emergency disable, rehearsed.
 *
 * The runbook's claim is that flipping IMMERSIVE_MODE_ENABLED off makes the
 * next eligible call use the legacy UI without a client release, and that an
 * Immersive call already running is left alone. Both halves matter and they
 * pull in opposite directions, which is exactly why they are worth rehearsing
 * rather than asserting.
 *
 * The client half is what can be rehearsed here: given a status response that
 * flips, does the next call go legacy and the current one stay put. The
 * deployment half -- that the environment variable reaches the response
 * without a redeploy -- is the Release Engineering owner's, and no unit test
 * can stand in for it.
 */
function status(immersive: boolean | undefined): ServiceStatus {
  return {
    service: "k-comms",
    version: "test",
    status: "operational",
    capabilities: {
      administration: true,
      attachment_scanning: true,
      bootstrap: false,
      guest_links: true,
      immersive_mode: immersive,
      instant_rooms: true,
      notifications: true,
      realtime: true,
      secure_account_actions: true,
      secure_media_actions: true,
      webhooks: true
    }
  };
}

const capabilities: UserCapabilities = {
  allow_audio_calls: true,
  allow_video_calls: true,
  allow_immersive_mode: true,
  allow_public_channels: true,
  message_edit_window_seconds: 900,
  max_attachment_bytes: 1024
};

function Surface({
  serviceStatus,
  conversationId,
  phase
}: {
  serviceStatus: ServiceStatus;
  conversationId?: string;
  phase?: string;
}) {
  const { mode } = useExperienceModeController({
    sessionState: conversationId && phase ? { conversationId, phase } : null,
    status: serviceStatus,
    capabilities,
    loading: false
  });
  return <span data-testid="mode">{mode}</span>;
}

const mode = () => screen.getByTestId("mode").textContent;

describe("emergency disable rehearsal", () => {
  beforeEach(() => {
    delete document.documentElement.dataset.experienceMode;
  });

  it("leaves a running immersive call alone when the switch is withdrawn", async () => {
    // "Existing calls retain their selected presentation unless a separately
    // tested same-session visual downgrade exists." There is no such
    // downgrade, so withdrawing mid-call must change nothing on screen.
    const view = render(
      <Surface serviceStatus={status(true)} conversationId="call-1" phase="joining" />
    );
    await waitFor(() => expect(mode()).toBe("immersive"));

    view.rerender(
      <Surface serviceStatus={status(false)} conversationId="call-1" phase="connected" />
    );
    await waitFor(() => expect(mode()).toBe("immersive"));
  });

  it("sends the next call to the legacy UI, with no client release involved", async () => {
    const view = render(
      <Surface serviceStatus={status(true)} conversationId="call-1" phase="joining" />
    );
    await waitFor(() => expect(mode()).toBe("immersive"));

    // The switch goes off while the first call is still up...
    view.rerender(
      <Surface serviceStatus={status(false)} conversationId="call-1" phase="connected" />
    );
    // ...the first call ends...
    view.rerender(<Surface serviceStatus={status(false)} />);
    await waitFor(() => expect(mode()).toBe("workspace"));

    // ...and the next one is legacy. Nothing was rebuilt or reloaded: the
    // only thing that changed is a field in a response the client already
    // polls.
    view.rerender(
      <Surface serviceStatus={status(false)} conversationId="call-2" phase="joining" />
    );
    await waitFor(() => expect(mode()).toBe("workspace"));
  });

  it("restores immersive entry when the switch comes back", async () => {
    // A rollback that cannot be rolled back is not a switch, it is a delete.
    const view = render(<Surface serviceStatus={status(false)} conversationId="call-1" phase="joining" />);
    await waitFor(() => expect(mode()).toBe("workspace"));

    view.rerender(<Surface serviceStatus={status(true)} />);
    view.rerender(
      <Surface serviceStatus={status(true)} conversationId="call-2" phase="joining" />
    );
    await waitFor(() => expect(mode()).toBe("immersive"));
  });

  it("treats a status response that drops the field as disabled", async () => {
    // A rollback to a build predating the switch omits it entirely. That has
    // to read as off, not as unknown-so-assume-on.
    render(<Surface serviceStatus={status(undefined)} conversationId="call-1" phase="joining" />);
    await waitFor(() => expect(mode()).toBe("workspace"));
  });

  it("publishes the workspace mode to the document, so the stage rules stop applying", async () => {
    // The fallback has to be complete: the CSS that fills the viewport keys
    // off this attribute, so a disable that left it stale would leave the
    // stage rules in force over a legacy dock.
    const view = render(
      <Surface serviceStatus={status(true)} conversationId="call-1" phase="joining" />
    );
    await waitFor(() =>
      expect(document.documentElement.dataset.experienceMode).toBe("immersive")
    );

    view.rerender(<Surface serviceStatus={status(false)} />);
    await waitFor(() =>
      expect(document.documentElement.dataset.experienceMode).toBe("workspace")
    );
  });
});
